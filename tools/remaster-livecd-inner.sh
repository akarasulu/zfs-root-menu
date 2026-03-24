#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<USAGE
Usage: $(basename "$0") --source-iso PATH --repo-root PATH --output-iso PATH [options]

Options:
  --source-iso PATH           Source ISO path inside the remaster chroot.
  --source-iso-url URL        Optional download URL if source ISO is missing.
  --repo-root PATH            Repo root inside the remaster chroot.
  --output-iso PATH           Output ISO path inside the remaster chroot.
  --authorized-keys-file PATH Optional authorized_keys source file path
                              inside the remaster chroot.
  --help                      Show this help.
USAGE
}

SOURCE_ISO=""
SOURCE_ISO_URL=${SOURCE_ISO_URL:-}
REPO_ROOT=""
OUTPUT_ISO=""
AUTHORIZED_KEYS_FILE=""
HOST_TIMEZONE=${HOST_TIMEZONE:-UTC}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-iso) SOURCE_ISO=${2:?}; shift 2 ;;
    --source-iso-url) SOURCE_ISO_URL=${2:?}; shift 2 ;;
    --repo-root) REPO_ROOT=${2:?}; shift 2 ;;
    --output-iso) OUTPUT_ISO=${2:?}; shift 2 ;;
    --authorized-keys-file) AUTHORIZED_KEYS_FILE=${2:?}; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

[[ -n "$SOURCE_ISO" ]] || { printf 'Missing --source-iso\n' >&2; exit 1; }
[[ -n "$REPO_ROOT" ]] || { printf 'Missing --repo-root\n' >&2; exit 1; }
[[ -n "$OUTPUT_ISO" ]] || { printf 'Missing --output-iso\n' >&2; exit 1; }

REMASTER_ROOT="$REPO_ROOT/build/remaster-work"
ISO_EXTRACT_DIR="$REMASTER_ROOT/iso"
ROOTFS_DIR="$REMASTER_ROOT/rootfs"
BOOT_IMAGE="$ISO_EXTRACT_DIR/boot/grub/efi.img"
SQUASHFS_IMAGE="$ISO_EXTRACT_DIR/live/filesystem.squashfs"
REPO_SCRIPT="$REPO_ROOT/zfs-root-menu.sh"
STAGED_INSTALLER="$ROOTFS_DIR/root/zfs-root-menu.sh"
STAGED_AUTHORIZED_KEYS="$ROOTFS_DIR/root/authorized_keys.pub"
GRUB_CFG="$ISO_EXTRACT_DIR/boot/grub/grub.cfg"
GRUB_BASE_CFG="$ISO_EXTRACT_DIR/boot/grub/config.cfg"
ISOLINUX_CFG="$ISO_EXTRACT_DIR/isolinux/isolinux.cfg"
ISOLINUX_LIVE_CFG="$ISO_EXTRACT_DIR/isolinux/live.cfg"

cleanup() {
  set +e
  for path in "$ROOTFS_DIR/dev/pts" "$ROOTFS_DIR/dev" "$ROOTFS_DIR/proc" "$ROOTFS_DIR/sys"; do
    if mountpoint -q "$path" 2>/dev/null; then
      umount -R "$path" 2>/dev/null || umount -l "$path" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT

normalize_source_iso_url() {
  local basename=$1
  if [[ -n "$SOURCE_ISO_URL" ]]; then
    printf '%s\n' "$SOURCE_ISO_URL"
    return 0
  fi
  if [[ $basename =~ ^debian-live-([0-9]+\.[0-9]+\.[0-9]+)-amd64-[^.]+\.iso$ ]]; then
    printf 'https://cdimage.debian.org/cdimage/archive/%s-live/amd64/iso-hybrid/%s\n' "${BASH_REMATCH[1]}" "$basename"
    return 0
  fi
  return 1
}

configure_bootloader_console() {
  [[ -f "$GRUB_CFG" ]] || { printf 'Missing GRUB config at %s\n' "$GRUB_CFG" >&2; exit 1; }
  [[ -f "$GRUB_BASE_CFG" ]] || { printf 'Missing GRUB base config at %s\n' "$GRUB_BASE_CFG" >&2; exit 1; }
  [[ -f "$ISOLINUX_CFG" ]] || { printf 'Missing ISOLINUX config at %s\n' "$ISOLINUX_CFG" >&2; exit 1; }
  [[ -f "$ISOLINUX_LIVE_CFG" ]] || { printf 'Missing ISOLINUX live config at %s\n' "$ISOLINUX_LIVE_CFG" >&2; exit 1; }

  python3 - "$GRUB_CFG" "$GRUB_BASE_CFG" "$ISOLINUX_CFG" "$ISOLINUX_LIVE_CFG" <<'PY_BOOT'
from pathlib import Path
import sys

grub_cfg = Path(sys.argv[1])
grub_base_cfg = Path(sys.argv[2])
isolinux_cfg = Path(sys.argv[3])
isolinux_live_cfg = Path(sys.argv[4])
serial_args = 'console=tty0 console=ttyS0,115200n8'

grub_text = grub_cfg.read_text()
header = 'set timeout_style=menu\nset timeout=2\n'
filtered = [line for line in grub_text.splitlines() if not line.startswith('set timeout_style=') and not line.startswith('set timeout=')]
grub_text = header + '\n'.join(filtered) + '\n'
grub_text = grub_text.replace(' boot=live components quiet splash', f' boot=live components quiet splash {serial_args}')
grub_text = grub_text.replace(' boot=live components   findiso=${iso_path} verify-checksums', f' boot=live components {serial_args} findiso=${{iso_path}} verify-checksums')
grub_cfg.write_text(grub_text)

grub_base_text = grub_base_cfg.read_text()
serial_block = 'serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1\nterminal_input console serial\nterminal_output console serial\n'
if serial_block not in grub_base_text:
    grub_base_text = grub_base_text.replace('insmod png\n\n', 'insmod png\n\n' + serial_block)
grub_base_text = grub_base_text.replace('source /boot/grub/theme.cfg\n\nterminal_output gfxterm\n', '')
grub_base_cfg.write_text(grub_base_text)

isolinux_text = isolinux_cfg.read_text()
if 'serial 0 115200' not in isolinux_text:
    isolinux_text = 'serial 0 115200\n' + isolinux_text
if 'timeout 0' in isolinux_text:
    isolinux_text = isolinux_text.replace('timeout 0', 'timeout 20', 1)
elif 'timeout ' not in isolinux_text:
    isolinux_text = isolinux_text.rstrip() + '\ntimeout 20\n'
isolinux_cfg.write_text(isolinux_text)

live_text = isolinux_live_cfg.read_text()
live_text = live_text.replace('append boot=live components quiet splash', f'append boot=live components quiet splash {serial_args}')
live_text = live_text.replace('append boot=live components memtest noapic noapm nodma nomce nosmp nosplash vga=788', f'append boot=live components memtest noapic noapm nodma nomce nosmp nosplash vga=788 {serial_args}')
isolinux_live_cfg.write_text(live_text)
PY_BOOT
}

if [[ ! -f "$SOURCE_ISO" ]]; then
  mkdir -p -- "$(dirname -- "$SOURCE_ISO")"
  rm -f -- "$SOURCE_ISO"
  DOWNLOAD_URL=$(normalize_source_iso_url "$(basename -- "$SOURCE_ISO")") || {
    printf 'Source ISO is missing and no download URL could be derived for %s\n' "$SOURCE_ISO" >&2
    exit 1
  }
  curl -fL "$DOWNLOAD_URL" -o "$SOURCE_ISO"
fi

[[ -x /usr/bin/xorriso ]] || { printf 'xorriso is required inside the remaster chroot\n' >&2; exit 1; }
[[ -x /usr/bin/unsquashfs ]] || { printf 'unsquashfs is required inside the remaster chroot\n' >&2; exit 1; }
[[ -x /usr/bin/mksquashfs ]] || { printf 'mksquashfs is required inside the remaster chroot\n' >&2; exit 1; }
[[ -f "$REPO_SCRIPT" ]] || { printf 'Missing installer script at %s\n' "$REPO_SCRIPT" >&2; exit 1; }

rm -rf -- "$REMASTER_ROOT"
mkdir -p -- "$ISO_EXTRACT_DIR" "$ROOTFS_DIR" "$(dirname -- "$OUTPUT_ISO")"

xorriso -osirrox on -indev "$SOURCE_ISO" -extract / "$ISO_EXTRACT_DIR"
[[ -f "$SQUASHFS_IMAGE" ]] || { printf 'Missing live filesystem image at %s\n' "$SQUASHFS_IMAGE" >&2; exit 1; }
[[ -f "$BOOT_IMAGE" ]] || { printf 'Missing EFI boot image at %s\n' "$BOOT_IMAGE" >&2; exit 1; }

configure_bootloader_console
unsquashfs -d "$ROOTFS_DIR" "$SQUASHFS_IMAGE"
install -m 0755 "$REPO_SCRIPT" "$STAGED_INSTALLER"
if [[ -n "$AUTHORIZED_KEYS_FILE" && -f "$AUTHORIZED_KEYS_FILE" ]]; then
  install -m 0600 "$AUTHORIZED_KEYS_FILE" "$STAGED_AUTHORIZED_KEYS"
  AUTHORIZED_KEYS_FILE=/root/authorized_keys.pub
fi
cp /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"
mount --bind /dev "$ROOTFS_DIR/dev"
mount --bind /dev/pts "$ROOTFS_DIR/dev/pts"
mount --bind /proc "$ROOTFS_DIR/proc"
mount --bind /sys "$ROOTFS_DIR/sys"

chroot "$ROOTFS_DIR" /usr/bin/env DEBIAN_FRONTEND=noninteractive AUTHORIZED_KEYS_FILE="$AUTHORIZED_KEYS_FILE" HOST_TIMEZONE="$HOST_TIMEZONE" /bin/bash <<'EOF_CHROOT'
set -Eeuo pipefail

rm -rf /etc/apt/sources.list.d/* || true
cat > /etc/apt/sources.list <<'APT'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
APT

apt-get clean
apt-get update
if [[ -n "${HOST_TIMEZONE:-}" && -e "/usr/share/zoneinfo/${HOST_TIMEZONE}" ]]; then
  ln -snf "/usr/share/zoneinfo/${HOST_TIMEZONE}" /etc/localtime
  printf '%s\n' "${HOST_TIMEZONE}" > /etc/timezone
fi
LIVE_KERNEL=$(basename /lib/modules/*)
apt-get install -y openssh-server sudo curl ca-certificates systemd-timesyncd efibootmgr build-essential dkms "linux-headers-${LIVE_KERNEL}" zfs-dkms zfsutils-linux
apt-get -f install -y
if command -v dkms >/dev/null 2>&1; then
  dkms autoinstall -k "$LIVE_KERNEL" || true
fi
mkdir -p /dev/pts
mountpoint -q /dev/pts || mount -t devpts devpts /dev/pts -o gid=5,mode=620,ptmxmode=000
modprobe zfs || true

if ! getent passwd user >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo user
fi
usermod -aG sudo user || true
printf 'user:user\n' | chpasswd

install -d -m 700 -o user -g user /home/user/.ssh
install -d -m 700 -o user -g user /home/user/.config
cat > /home/user/.config/kscreenlockerrc <<'KSCREENLOCK'
[Daemon]
Autolock=false
LockOnResume=false
Timeout=0
KSCREENLOCK
chown user:user /home/user/.config/kscreenlockerrc
chmod 600 /home/user/.config/kscreenlockerrc

cat > /home/user/.config/powermanagementprofilesrc <<'POWERDEVIL'
[AC][DimDisplay]
idleTime=0

[AC][DPMSControl]
idleTime=0

[AC][HandleButtonEvents]
lidAction=32

[AC][SuspendAndShutdown]
autoSuspendAction=0
autoSuspendIdleTimeoutSec=0

[Battery][DimDisplay]
idleTime=0

[Battery][DPMSControl]
idleTime=0

[Battery][HandleButtonEvents]
lidAction=32

[Battery][SuspendAndShutdown]
autoSuspendAction=0
autoSuspendIdleTimeoutSec=0

[LowBattery][DimDisplay]
idleTime=0

[LowBattery][DPMSControl]
idleTime=0

[LowBattery][HandleButtonEvents]
lidAction=32

[LowBattery][SuspendAndShutdown]
autoSuspendAction=0
autoSuspendIdleTimeoutSec=0
POWERDEVIL
chown user:user /home/user/.config/powermanagementprofilesrc
chmod 600 /home/user/.config/powermanagementprofilesrc

if [[ -n "${AUTHORIZED_KEYS_FILE:-}" && -f "${AUTHORIZED_KEYS_FILE:-}" ]]; then
  install -m 600 -o user -g user "$AUTHORIZED_KEYS_FILE" /home/user/.ssh/authorized_keys
  chown user:user /home/user/.ssh/authorized_keys
  chmod 600 /home/user/.ssh/authorized_keys
fi

install -m 0755 /root/zfs-root-menu.sh /home/user/zfs-root-menu.sh
chown user:user /home/user/zfs-root-menu.sh

cat > /etc/ssh/sshd_config.d/99-zfs-root-menu.conf <<CFG
PasswordAuthentication yes
PubkeyAuthentication yes
PermitRootLogin no
CFG

cat > /etc/systemd/system/dev-pts.mount <<'UNIT'
[Unit]
Description=Pseudo-terminal file system
Documentation=man:hier(7) man:pts(4)
DefaultDependencies=no
ConditionPathExists=/dev/pts
After=local-fs-pre.target systemd-remount-fs.service
Before=local-fs.target ssh.service getty.target multi-user.target systemd-user-sessions.service

[Mount]
What=devpts
Where=/dev/pts
Type=devpts
Options=gid=5,mode=620,ptmxmode=000

[Install]
WantedBy=local-fs.target
UNIT

systemctl enable dev-pts.mount || true
systemctl enable systemd-timesyncd || true
systemctl enable ssh.service || true
EOF_CHROOT

for path in "$ROOTFS_DIR/dev/pts" "$ROOTFS_DIR/dev" "$ROOTFS_DIR/proc" "$ROOTFS_DIR/sys"; do
  if mountpoint -q "$path" 2>/dev/null; then
    umount -R "$path" 2>/dev/null || umount -l "$path" 2>/dev/null || true
  fi
done

rm -f "$ROOTFS_DIR/etc/resolv.conf"
find "$ROOTFS_DIR/var/lib/apt/lists" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
rm -rf "$ROOTFS_DIR/var/cache/apt/archives"/*.deb 2>/dev/null || true

mksquashfs "$ROOTFS_DIR" "$SQUASHFS_IMAGE" -noappend -comp xz
printf '%s\n' "$(du -sx --block-size=1 "$ROOTFS_DIR" | cut -f1)" > "$ISO_EXTRACT_DIR/live/filesystem.size"

(
  cd "$ISO_EXTRACT_DIR"
  find . -type f ! -name md5sum.txt -print0 | sort -z | xargs -0 md5sum > md5sum.txt
)

VOLID=$(xorriso -indev "$SOURCE_ISO" -pvd_info 2>/dev/null | awk -F': ' '/Volume id/ {print $2; exit}')
VOLID=${VOLID:-ZFS_ROOT_MENU_LIVE}
ISOHDPFX=""
for candidate in /usr/lib/ISOLINUX/isohdpfx.bin /usr/lib/syslinux/isohdpfx.bin; do
  if [[ -f "$candidate" ]]; then
    ISOHDPFX=$candidate
    break
  fi
done
[[ -n "$ISOHDPFX" ]] || { printf 'Could not find isohybrid MBR binary\n' >&2; exit 1; }

xorriso -as mkisofs \
  -r -J -joliet-long -iso-level 3 \
  -V "$VOLID" \
  -o "$OUTPUT_ISO" \
  -isohybrid-mbr "$ISOHDPFX" \
  -partition_offset 16 \
  -c isolinux/boot.cat \
  -b isolinux/isolinux.bin \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -append_partition 2 0xef "$BOOT_IMAGE" \
  -e --interval:appended_partition_2:all:: \
  -no-emul-boot \
  -isohybrid-gpt-basdat \
  "$ISO_EXTRACT_DIR"
