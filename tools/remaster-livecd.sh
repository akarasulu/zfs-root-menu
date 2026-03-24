#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  exec sudo --preserve-env=AUTHORIZED_KEYS_URL,SOURCE_ISO_URL,REMIX_ISO_NAME "$0" "$@"
fi

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Create a remastered Debian Trixie live ISO inside a Debian Trixie debootstrap chroot.

Options:
  --source-iso PATH           Source ISO path or symlink in the repo.
                              Default: first debian-live-*.iso in repo root.
  --output-iso PATH           Output ISO path.
                              Default: ./build/
                                       zfs-root-menu-live.iso
  --chroot-dir PATH           Trixie remaster chroot path.
                              Default: ./.remaster-chroot
  --authorized-keys-url URL   Optional public key URL to append to
                              /home/user/.ssh/authorized_keys in the live ISO.
  --refresh-chroot            Recreate the remaster chroot from scratch.
  --help                      Show this help.

Environment:
  SOURCE_ISO_URL              Download URL if the source ISO is missing.
  AUTHORIZED_KEYS_URL         Optional public key URL.
  REMIX_ISO_NAME              Output ISO basename override.
USAGE
}

SOURCE_ISO_ARG=""
OUTPUT_ISO_ARG=""
CHROOT_DIR="$ROOT_DIR/.remaster-chroot"
AUTHORIZED_KEYS_URL=${AUTHORIZED_KEYS_URL:-}
REFRESH_CHROOT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-iso) SOURCE_ISO_ARG=${2:?}; shift 2 ;;
    --output-iso) OUTPUT_ISO_ARG=${2:?}; shift 2 ;;
    --chroot-dir) CHROOT_DIR=${2:?}; shift 2 ;;
    --authorized-keys-url) AUTHORIZED_KEYS_URL=${2:?}; shift 2 ;;
    --refresh-chroot) REFRESH_CHROOT=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

find_default_source_iso() {
  local candidate

  candidate="$ROOT_DIR/debian-live.iso"
  if [[ -e "$candidate" || -L "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  for candidate in "$ROOT_DIR"/debian-live-*.iso; do
    if [[ -e "$candidate" || -L "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

resolve_authorized_keys_file() {
  local resolved_path=""
  local fallback_link="$ROOT_DIR/ssh_id.pub"

  mkdir -p -- "$CHROOT_DIR/tmp"

  if [[ -n "$AUTHORIZED_KEYS_URL" ]]; then
    if [[ $AUTHORIZED_KEYS_URL == file://* ]]; then
      resolved_path=${AUTHORIZED_KEYS_URL#file://}
      [[ -f "$resolved_path" ]] || {
        printf 'Authorized keys file URL did not resolve to a valid file: %s\n' "$AUTHORIZED_KEYS_URL" >&2
        exit 1
      }
      cp -- "$resolved_path" "$CHROOT_DIR/tmp/authorized_keys.pub"
      printf '%s\n' /tmp/authorized_keys.pub
      return 0
    fi

    curl -fsSL "$AUTHORIZED_KEYS_URL" -o "$CHROOT_DIR/tmp/authorized_keys.pub"
    printf '%s\n' /tmp/authorized_keys.pub
    return 0
  fi

  if [[ -e "$fallback_link" || -L "$fallback_link" ]]; then
    resolved_path=$(readlink -f -- "$fallback_link" 2>/dev/null || true)
    if [[ -n "$resolved_path" && -f "$resolved_path" ]]; then
      cp -- "$resolved_path" "$CHROOT_DIR/tmp/authorized_keys.pub"
      printf '%s\n' /tmp/authorized_keys.pub
      return 0
    fi
  fi

  return 1
}

SOURCE_ISO=${SOURCE_ISO_ARG:-}
if [[ -z "$SOURCE_ISO" ]]; then
  SOURCE_ISO=$(find_default_source_iso) || {
    printf 'No default Debian live ISO found in %s (looked for debian-live.iso and debian-live-*.iso)\n' "$ROOT_DIR" >&2
    exit 1
  }
fi

if [[ "$SOURCE_ISO" != /* ]]; then
  SOURCE_ISO="$ROOT_DIR/$SOURCE_ISO"
fi

SOURCE_ISO_BASENAME=$(basename -- "$SOURCE_ISO")
OUTPUT_ISO=${OUTPUT_ISO_ARG:-"$ROOT_DIR/build/${REMIX_ISO_NAME:-zfs-root-menu-live.iso}"}
if [[ "$OUTPUT_ISO" != /* ]]; then
  OUTPUT_ISO="$ROOT_DIR/$OUTPUT_ISO"
fi
mkdir -p -- "$(dirname -- "$OUTPUT_ISO")"

HOST_SOURCE_ISO=""
if [[ -e "$SOURCE_ISO" ]]; then
  HOST_SOURCE_ISO=$(readlink -f -- "$SOURCE_ISO")
elif [[ -L "$SOURCE_ISO" ]]; then
  HOST_SOURCE_ISO=""
fi

cleanup() {
  set +e
  for path in "$CHROOT_DIR/work" "$CHROOT_DIR/mnt/source-iso" "$CHROOT_DIR/dev/pts" "$CHROOT_DIR/dev" "$CHROOT_DIR/proc" "$CHROOT_DIR/sys"; do
    if mountpoint -q "$path" 2>/dev/null; then
      umount -R "$path" 2>/dev/null || umount -l "$path" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT

if (( REFRESH_CHROOT == 1 )) && [[ -d "$CHROOT_DIR" ]]; then
  rm -rf -- "$CHROOT_DIR"
fi

if [[ ! -x "$CHROOT_DIR/usr/bin/apt-get" ]]; then
  mkdir -p -- "$CHROOT_DIR"
  debootstrap --variant=minbase trixie "$CHROOT_DIR" http://deb.debian.org/debian
fi

cp /etc/resolv.conf "$CHROOT_DIR/etc/resolv.conf"
mkdir -p "$CHROOT_DIR"/work "$CHROOT_DIR"/mnt/source-iso
mountpoint -q "$CHROOT_DIR/dev" || mount --bind /dev "$CHROOT_DIR/dev"
mountpoint -q "$CHROOT_DIR/dev/pts" || mount --bind /dev/pts "$CHROOT_DIR/dev/pts"
mountpoint -q "$CHROOT_DIR/proc" || mount --bind /proc "$CHROOT_DIR/proc"
mountpoint -q "$CHROOT_DIR/sys" || mount --bind /sys "$CHROOT_DIR/sys"
mountpoint -q "$CHROOT_DIR/work" || mount --bind "$ROOT_DIR" "$CHROOT_DIR/work"
if [[ -n "$HOST_SOURCE_ISO" ]]; then
  mountpoint -q "$CHROOT_DIR/mnt/source-iso" || mount --bind "$(dirname -- "$HOST_SOURCE_ISO")" "$CHROOT_DIR/mnt/source-iso"
fi

CHROOT_AUTHORIZED_KEYS_FILE=""
if CHROOT_AUTHORIZED_KEYS_FILE=$(resolve_authorized_keys_file); then
  :
fi

chroot "$CHROOT_DIR" /usr/bin/env DEBIAN_FRONTEND=noninteractive bash -lc '
  apt-get update
  apt-get install -y ca-certificates curl python3 rsync squashfs-tools xorriso isolinux syslinux-common
'

INNER_SOURCE_ISO="/work/$SOURCE_ISO_BASENAME"
if [[ -n "$HOST_SOURCE_ISO" ]]; then
  INNER_SOURCE_ISO="/mnt/source-iso/$(basename -- "$HOST_SOURCE_ISO")"
fi

INNER_CMD=(/work/tools/remaster-livecd-inner.sh
  --source-iso "$INNER_SOURCE_ISO"
  --repo-root /work
  --output-iso "/work/${OUTPUT_ISO#$ROOT_DIR/}")

if [[ -n "$CHROOT_AUTHORIZED_KEYS_FILE" ]]; then
  INNER_CMD+=(--authorized-keys-file "$CHROOT_AUTHORIZED_KEYS_FILE")
fi
if [[ -n ${SOURCE_ISO_URL:-} ]]; then
  INNER_CMD+=(--source-iso-url "$SOURCE_ISO_URL")
fi

chroot "$CHROOT_DIR" /usr/bin/env SOURCE_ISO_URL="${SOURCE_ISO_URL:-}" "${INNER_CMD[@]}"

printf 'Remastered ISO written to %s\n' "$OUTPUT_ISO"
