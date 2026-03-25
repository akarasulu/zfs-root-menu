#!/usr/bin/env bash
set -Eeuo pipefail

POOL="${POOL:-zroot}"
MNT="${MNT:-/mnt}"
ESP1="${ESP1:-/dev/disk/by-id/ata-HI-LEVEL_ELITE_SERIES_1TB_SSD_LTGF251002381-part1}"
ESP2="${ESP2:-/dev/disk/by-id/ata-HI-LEVEL_ELITE_SERIES_1TB_SSD_LTGF251002461-part1}"
LOG_PATH="${LOG:-}"
AUTO_LOG=1

fail=0

ok() { printf 'OK: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*"; fail=1; }

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --log PATH       Verify against a specific installer log file
  --auto-log       Use the newest /tmp/zfs-root-menu-*.log automatically (default)
  --pool NAME      ZFS pool name (default: zroot)
  --mountpoint DIR Target mountpoint (default: /mnt)
  --esp1 DEV       ESP1 device path
  --esp2 DEV       ESP2 device path
  -h, --help       Show this help

You can also set LOG=/path/to/log instead of --log.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --log) LOG_PATH=${2:?}; shift 2 ;;
    --auto-log) AUTO_LOG=1; shift ;;
    --pool) POOL=${2:?}; shift 2 ;;
    --mountpoint) MNT=${2:?}; shift 2 ;;
    --esp1) ESP1=${2:?}; shift 2 ;;
    --esp2) ESP2=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run as root (sudo su -)"
    exit 2
  fi
}

latest_log() {
  ls -1t /tmp/zfs-root-menu-*.log 2>/dev/null | head -n1 || true
}

resolve_log() {
  if [[ -n "$LOG_PATH" ]]; then
    [[ -f "$LOG_PATH" ]] || { bad "Specified log not found: $LOG_PATH"; return; }
    return
  fi

  if [[ "$AUTO_LOG" -eq 1 ]]; then
    LOG_PATH="$(latest_log)"
    [[ -n "$LOG_PATH" ]] || bad "No installer log found in /tmp"
    return
  fi

  bad "No log selected. Use --log /tmp/zfs-root-menu-YYYYMMDD-HHMMSS.log (or --auto-log)."
  echo "Recent logs:"
  ls -1t /tmp/zfs-root-menu-*.log 2>/dev/null | head -n 5 || true
}

check_log() {
  [[ -n "$LOG_PATH" ]] || return
  echo "LOG=$LOG_PATH"
  if grep -q 'DONE - REBOOT NOW' "$LOG_PATH"; then
    ok "Installer completion marker present"
  else
    bad "Missing 'DONE - REBOOT NOW' in installer log"
  fi
  if grep -q 'ERROR:' "$LOG_PATH"; then
    bad "Installer log contains ERROR lines"
    grep -n 'ERROR:' "$LOG_PATH" || true
  else
    ok "No ERROR lines in installer log"
  fi
}

ensure_target_mounted() {
  if zpool status "$POOL" >/dev/null 2>&1; then
    ok "Pool $POOL is available"
  else
    bad "Pool $POOL is not available"
    return
  fi

  zfs mount "${POOL}/ROOT/trixie" 2>/dev/null || true
  zfs mount -a 2>/dev/null || true

  if mount | grep -q " on ${MNT} type zfs "; then
    ok "Target root is mounted at $MNT"
  else
    bad "Target root is not mounted at $MNT"
  fi
}

check_target_files() {
  [[ -f "${MNT}/etc/debian_version" ]] && ok "rootfs present" || bad "missing ${MNT}/etc/debian_version"
  [[ -f "${MNT}/var/lib/dpkg/status" ]] && ok "dpkg status present" || bad "missing ${MNT}/var/lib/dpkg/status"
  [[ -f "${MNT}/etc/hostid" ]] && ok "hostid present" || bad "missing ${MNT}/etc/hostid"

  if ls -1 "${MNT}"/boot/initrd.img-* >/dev/null 2>&1; then
    ok "initrd present under ${MNT}/boot"
  else
    bad "missing initrd under ${MNT}/boot"
  fi
}

check_ssh_policy_and_key() {
  local cfg="${MNT}/etc/ssh/sshd_config.d/99-zfs-root-menu.conf"
  if [[ -f "$cfg" ]]; then
    ok "sshd policy file present"
    grep -Eq '^PermitRootLogin[[:space:]]+prohibit-password' "$cfg" || bad "PermitRootLogin is not prohibit-password"
    grep -Eq '^PasswordAuthentication[[:space:]]+no' "$cfg" || bad "PasswordAuthentication is not no"
    grep -Eq '^PubkeyAuthentication[[:space:]]+yes' "$cfg" || bad "PubkeyAuthentication is not yes"
  else
    bad "missing $cfg"
  fi

  if [[ -s "${MNT}/root/.ssh/authorized_keys" ]]; then
    ok "root authorized_keys present"
  else
    bad "missing ${MNT}/root/.ssh/authorized_keys"
  fi
}

mount_esp() {
  mkdir -p "${MNT}/boot/efi" "${MNT}/boot/efi2"
  mountpoint -q "${MNT}/boot/efi" || mount "$ESP1" "${MNT}/boot/efi" 2>/dev/null || true
  mountpoint -q "${MNT}/boot/efi2" || mount "$ESP2" "${MNT}/boot/efi2" 2>/dev/null || true
}

check_efi_payloads() {
  mount_esp
  [[ -s "${MNT}/boot/efi/EFI/ZBM/VMLINUZ.EFI" ]] && ok "ESP1 ZBM payload present" || bad "ESP1 missing EFI/ZBM/VMLINUZ.EFI"
  [[ -s "${MNT}/boot/efi/EFI/BOOT/BOOTX64.EFI" ]] && ok "ESP1 fallback payload present" || bad "ESP1 missing EFI/BOOT/BOOTX64.EFI"
  [[ -s "${MNT}/boot/efi2/EFI/ZBM/VMLINUZ.EFI" ]] && ok "ESP2 ZBM payload present" || bad "ESP2 missing EFI/ZBM/VMLINUZ.EFI"
  [[ -s "${MNT}/boot/efi2/EFI/BOOT/BOOTX64.EFI" ]] && ok "ESP2 fallback payload present" || bad "ESP2 missing EFI/BOOT/BOOTX64.EFI"
}

show_boot_entries() {
  if command -v efibootmgr >/dev/null 2>&1; then
    echo
    echo "UEFI entries:"
    efibootmgr -v | grep -E 'Boot[0-9A-F]{4}\* (ZFSBootMenu|ZFSBootMenu Mirror|UEFI OS)' || true
  else
    warn "efibootmgr not installed in live environment"
  fi
}

dump_debug_on_fail() {
  echo
  echo "--- DEBUG (auto) ---"
  if [[ -n "$LOG_PATH" && -f "$LOG_PATH" ]]; then
    echo "Log markers:"
    grep -nE 'Running target chroot configuration|Target chroot configuration complete|DONE - REBOOT NOW|ERROR:|Missing /var/lib/dpkg/status|Dataset .* is not mounted|missing /boot/initrd|cannot unmount' "$LOG_PATH" || true
    echo
    echo "Log tail (last 120):"
    tail -n 120 "$LOG_PATH" || true
  fi
  echo
  echo "Runtime state:"
  zpool status "$POOL" || true
  zfs list -o name,mountpoint,mounted | grep -E "${POOL}/(ROOT|boot|var|var/lib|var/log|var/cache|root)" || true
  mount | grep " on ${MNT}" || true
  ls -ld "${MNT}" "${MNT}/boot" "${MNT}/var" "${MNT}/var/lib" "${MNT}/root" "${MNT}/root/.ssh" 2>/dev/null || true
  ls -l "${MNT}/var/lib/dpkg/status" "${MNT}"/boot/initrd.img-* "${MNT}/root/.ssh/authorized_keys" 2>/dev/null || true
}

main() {
  need_root
  resolve_log
  check_log
  ensure_target_mounted
  check_target_files
  check_ssh_policy_and_key
  check_efi_payloads
  show_boot_entries

  echo
  if [[ "$fail" -eq 0 ]]; then
    echo "RESULT: PASS"
  else
    echo "RESULT: FAIL"
    dump_debug_on_fail
  fi
  exit "$fail"
}

main "$@"
