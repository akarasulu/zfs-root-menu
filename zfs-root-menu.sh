#!/usr/bin/env bash
set -euo pipefail

LOG_DIR=${ZRM_LOG_DIR:-/tmp}
mkdir -p "$LOG_DIR"
LOG_FILE=${ZRM_LOG_FILE:-$LOG_DIR/zfs-root-menu-$(date +%Y%m%d-%H%M%S).log}
exec > >(tee -a "$LOG_FILE") 2>&1
printf 'Logging to %s\n' "$LOG_FILE"

###############################################################################

# Stein: Debian Trixie + ZFS mirror root + ZFSBootMenu

# ALWAYS DESTRUCTIVE + SELF-HEALING ZFS MODULE

###############################################################################

log(){ echo -e "\n==> $*"; }
die(){ echo -e "\nERROR: $*" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
APT_INSTALL=(apt-get install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

auto_preseed_zfs() {
  if command -v debconf-set-selections >/dev/null 2>&1; then
    debconf-set-selections <<'EOF_DEBCONF'
zfs-dkms zfs-dkms/note-incompatible-licenses note
zfs-dkms zfs-dkms/stop build failure boolean true
EOF_DEBCONF
  fi
}

usage() {
  cat <<USAGE
Usage: $(basename "$0") --name STRING --size STRING [options]

Destructive Debian + mirrored ZFS root installer for two matching disks.
The name filter matches the combined vendor/model/size identity, case-insensitively.

Options:
  --name STRING      Required model/vendor/name substring filter
  --size STRING      Required size substring filter
  --pool NAME        ZFS pool name (default: zroot)
  --hostname NAME    Target hostname (default: stein)
  --release NAME     Debian release (default: trixie)
  --mountpoint PATH  Temporary install mountpoint (default: /mnt)
  --dry-run          Print matched drives and exit without changes
  --repair-chroot    Reuse an existing target at the mountpoint and rerun only
                     the target chroot configuration/build steps
  --help             Show this help
USAGE
}

POOL="zroot"
HOSTNAME="stein"
RELEASE="trixie"
MNT="/mnt"
DRIVE_NAME_FILTER=""
DRIVE_SIZE_FILTER=""
DRY_RUN=0
REPAIR_CHROOT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) DRIVE_NAME_FILTER=${2:?}; shift 2 ;;
    --size) DRIVE_SIZE_FILTER=${2:?}; shift 2 ;;
    --pool) POOL=${2:?}; shift 2 ;;
    --hostname) HOSTNAME=${2:?}; shift 2 ;;
    --release) RELEASE=${2:?}; shift 2 ;;
    --mountpoint) MNT=${2:?}; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --repair-chroot) REPAIR_CHROOT=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

if (( REPAIR_CHROOT == 0 )); then
  [[ -n "$DRIVE_NAME_FILTER" ]] || die '--name is required'
  [[ -n "$DRIVE_SIZE_FILTER" ]] || die '--size is required'
fi

normalize_filter() {
  local value=${1,,}
  value=${value// /}
  value=${value//ib/}
  printf '%s\n' "$value"
}

resolve_disk_stable_path() {
  local disk=$1
  local real target link
  real=$(realpath "$disk" 2>/dev/null || printf '%s' "$disk")

  while IFS= read -r link; do
    [[ -e $link ]] || continue
    target=$(realpath "$link" 2>/dev/null || true)
    [[ $target == "$real" ]] || continue
    case ${link##*/} in
      *-part*) continue ;;
      ata-*)
        printf '%s\n' "$link"
        return 0
        ;;
    esac
  done < <(find /dev/disk/by-id -maxdepth 1 -type l | sort)

  while IFS= read -r link; do
    [[ -e $link ]] || continue
    target=$(realpath "$link" 2>/dev/null || true)
    [[ $target == "$real" ]] || continue
    case ${link##*/} in
      *-part*) continue ;;
      wwn-*|nvme-*|scsi-*)
        printf '%s\n' "$link"
        return 0
        ;;
    esac
  done < <(find /dev/disk/by-id -maxdepth 1 -type l | sort)

  printf '%s\n' "$disk"
}

partition_path() {
  local disk=$1
  local part=$2

  if [[ $disk == /dev/disk/by-*/* ]]; then
    printf '%s-part%s\n' "$disk" "$part"
  elif [[ $disk =~ [0-9]$ ]]; then
    printf '%sp%s\n' "$disk" "$part"
  else
    printf '%s%s\n' "$disk" "$part"
  fi
}

find_matching_disks() {
  local name_filter=${DRIVE_NAME_FILTER,,}
  local size_filter
  size_filter=$(normalize_filter "$DRIVE_SIZE_FILTER")
  local line name type rm ro hotplug model vendor size identity normalized_identity

  while IFS= read -r line; do
    [[ $line =~ NAME=\"([^\"]*)\" ]] || continue
    name=${BASH_REMATCH[1]}
    [[ $line =~ TYPE=\"([^\"]*)\" ]] || continue
    type=${BASH_REMATCH[1]}
    [[ $line =~ RM=\"([^\"]*)\" ]] || continue
    rm=${BASH_REMATCH[1]}
    [[ $line =~ RO=\"([^\"]*)\" ]] || continue
    ro=${BASH_REMATCH[1]}
    [[ $line =~ HOTPLUG=\"([^\"]*)\" ]] || continue
    hotplug=${BASH_REMATCH[1]}
    if [[ $line =~ MODEL=\"([^\"]*)\" ]]; then
      model=${BASH_REMATCH[1]}
    else
      model=""
    fi
    if [[ $line =~ VENDOR=\"([^\"]*)\" ]]; then
      vendor=${BASH_REMATCH[1]}
    else
      vendor=""
    fi
    [[ $line =~ SIZE=\"([^\"]*)\" ]] || continue
    size=${BASH_REMATCH[1]}

    [[ $type == "disk" ]] || continue
    [[ $rm == "0" && $ro == "0" && $hotplug == "0" ]] || continue
    identity="${vendor} ${model} ${size}"
    normalized_identity=$(normalize_filter "$identity")
    identity=${identity,,}
    [[ $identity == *$name_filter* ]] || continue
    [[ $normalized_identity == *$size_filter* ]] || continue
    printf '/dev/%s\n' "$name"
  done < <(lsblk -dnP -o NAME,TYPE,RM,RO,HOTPLUG,MODEL,VENDOR,SIZE)
}

DISKS=()
DISK1=""
DISK2=""
ESP1=""
ESP2=""
ZFS1=""
ZFS2=""
ROOT_DS="${POOL}/ROOT/${RELEASE}"
NIC_DRIVERS=()
BOOT_NET_IFACE=""
BOOT_NET_MAC=""
INSTALL_TIMEZONE=""
ROOT_PASSWORD=${ROOT_PASSWORD:-root}

collect_boot_network() {
  local route_iface mac
  route_iface=$(ip route show default 2>/dev/null | awk '{print $5; exit}' || true)
  if [[ -n $route_iface && -e /sys/class/net/$route_iface/address ]]; then
    mac=$(cat /sys/class/net/$route_iface/address 2>/dev/null || true)
    if [[ -n $mac ]]; then
      BOOT_NET_IFACE=$route_iface
      BOOT_NET_MAC=$mac
    fi
  fi
}

detect_install_timezone() {
  if [[ -n "${HOST_TIMEZONE:-}" ]]; then
    INSTALL_TIMEZONE="$HOST_TIMEZONE"
  elif [[ -s /etc/timezone ]]; then
    INSTALL_TIMEZONE=$(cat /etc/timezone)
  elif [[ -L /etc/localtime ]]; then
    INSTALL_TIMEZONE=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')
  else
    INSTALL_TIMEZONE="UTC"
  fi
}

ensure_time_sync() {
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-ntp true >/dev/null 2>&1 || true
  fi
  systemctl restart systemd-timesyncd >/dev/null 2>&1 || true
  sleep 2
}

collect_nic_drivers() {
  local netdir iface driver
  for netdir in /sys/class/net/*; do
    iface=${netdir##*/}
    [[ $iface == lo ]] && continue
    driver=$(readlink -f "$netdir/device/driver/module" 2>/dev/null | xargs -r basename 2>/dev/null || true)
    [[ -n $driver ]] || continue
    [[ " ${NIC_DRIVERS[*]} " == *" $driver "* ]] || NIC_DRIVERS+=("$driver")
  done
}


infer_existing_layout() {
  local member pkname root_candidate
  mapfile -t DISKS < <(zpool status -P "$POOL" 2>/dev/null | awk '/\/dev\// {print $1}' | head -n 2)
  [[ ${#DISKS[@]} -eq 2 ]] || die "Could not determine existing pool members for $POOL"

  DISK1=""
  DISK2=""
  for member in "${DISKS[@]}"; do
    pkname=$(lsblk -no PKNAME "$member" 2>/dev/null || true)
    [[ -n "$pkname" ]] || die "Could not determine parent disk for $member"
    if [[ -z "$DISK1" ]]; then
      DISK1=$(resolve_disk_stable_path "/dev/$pkname")
      ZFS1="$member"
      ESP1=$(partition_path "$DISK1" 1)
    else
      DISK2=$(resolve_disk_stable_path "/dev/$pkname")
      ZFS2="$member"
      ESP2=$(partition_path "$DISK2" 1)
    fi
  done

  if ! zfs list "$ROOT_DS" >/dev/null 2>&1; then
    root_candidate=$(zfs list -H -o name 2>/dev/null | awk -v p="$POOL/ROOT/" 'index($0,p)==1 { print; exit }')
    [[ -n "$root_candidate" ]] || die "Could not determine root dataset for $POOL"
    ROOT_DS="$root_candidate"
  fi
}

if (( REPAIR_CHROOT == 0 )); then
  mapfile -t DISKS < <(find_matching_disks)
  [[ ${#DISKS[@]} -eq 2 ]] || die "Expected exactly 2 matching disks for --name '$DRIVE_NAME_FILTER' and --size '$DRIVE_SIZE_FILTER', found ${#DISKS[@]}"
  DISK1=$(resolve_disk_stable_path "${DISKS[0]}")
  DISK2=$(resolve_disk_stable_path "${DISKS[1]}")
  ESP1=$(partition_path "$DISK1" 1)
  ESP2=$(partition_path "$DISK2" 1)
  ZFS1=$(partition_path "$DISK1" 2)
  ZFS2=$(partition_path "$DISK2" 2)
fi

stage_target_root_authorized_keys() {
  local candidate
  for candidate in /root/.ssh/authorized_keys /home/user/.ssh/authorized_keys; do
    if [[ -s "$candidate" ]]; then
      install -d -m 700 "$MNT/root/.ssh"
      install -m 600 "$candidate" "$MNT/root/.ssh/authorized_keys"
      chown -R root:root "$MNT/root/.ssh"
      log "Staged target root authorized_keys from $candidate"
      return 0
    fi
  done
  log "No root authorized_keys found in live environment; SSH key login will not be pre-seeded"
}

ensure_target_datasets_mounted() {
  local ds
  for ds in "$ROOT_DS"; do
    if zfs list "$ds" >/dev/null 2>&1; then
      if [[ "$(zfs get -H -o value mounted "$ds")" != "yes" ]]; then
        zfs mount "$ds" 2>/dev/null || true
      fi
      [[ "$(zfs get -H -o value mounted "$ds")" == "yes" ]] || die "Dataset $ds is not mounted before chroot"
    fi
  done
}

print_matched_disks() {
  local disk
  printf 'Matched install disks:\n'
  for disk in "$DISK1" "$DISK2"; do
    lsblk -dn -o NAME,MODEL,VENDOR,SIZE,TYPE "$disk"
  done
  printf 'Planned EFI partitions: %s %s\n' "$ESP1" "$ESP2"
  printf 'Planned ZFS members: %s %s\n' "$ZFS1" "$ZFS2"
}

ensure_live_zfs_tools() {
  command -v zpool >/dev/null 2>&1 || die "Live ISO is missing zpool; bake zfsutils-linux into the remastered ISO"
  command -v zfs >/dev/null 2>&1 || die "Live ISO is missing zfs; bake zfsutils-linux into the remastered ISO"

  if [[ ! -d /sys/module/zfs ]]; then
    log "Loading ZFS module"
    modprobe zfs || die "Live ISO is missing a working ZFS kernel module; bake ZFS support into the remastered ISO"
  fi

  [ -d /sys/module/zfs ] || die "ZFS module not loaded"
}

prepare_existing_target() {
  log "Preparing existing target at $MNT"

  ensure_live_zfs_tools
  detect_install_timezone
  ensure_time_sync

  if ! zpool list "$POOL" >/dev/null 2>&1; then
    zpool import -N -R "$MNT" "$POOL" >/dev/null 2>&1       || zpool import -f -N -R "$MNT" "$POOL" >/dev/null 2>&1       || zpool import -N -R "$MNT" >/dev/null 2>&1       || zpool import -f -N -R "$MNT" >/dev/null 2>&1       || die "Could not import existing pool $POOL"
  fi

  infer_existing_layout
  mkdir -p "$MNT"
  zfs mount "$ROOT_DS" 2>/dev/null || true
  zfs mount -a 2>/dev/null || true
  ensure_target_datasets_mounted

  mkdir -p "$MNT/boot/efi" "$MNT/boot/efi2"
  mountpoint -q "$MNT/boot/efi" || mount "$ESP1" "$MNT/boot/efi"

  if ! mountpoint -q "$MNT/dev"; then
    mount --rbind /dev "$MNT/dev"
    mount --make-rslave "$MNT/dev"
  fi
  if ! mountpoint -q "$MNT/proc"; then
    mount --rbind /proc "$MNT/proc"
    mount --make-rslave "$MNT/proc"
  fi
  if ! mountpoint -q "$MNT/sys"; then
    mount --rbind /sys "$MNT/sys"
    mount --make-rslave "$MNT/sys"
  fi

  [ -f "$MNT/etc/debian_version" ] || die "Existing target root not found at $MNT"
}

force_release_pool() {
  local attempt
  for attempt in 1 2 3; do
    zfs unmount -r "$POOL" 2>/dev/null || true
    umount -Rl "$MNT/dev" 2>/dev/null || true
    umount -Rl "$MNT/proc" 2>/dev/null || true
    umount -Rl "$MNT/sys" 2>/dev/null || true
    umount -Rl "$MNT/run" 2>/dev/null || true
    umount -Rl "$MNT/boot/efi2" 2>/dev/null || true
    umount -Rl "$MNT/boot/efi" 2>/dev/null || true
    umount -Rl "$MNT" 2>/dev/null || true
    umount -l "$MNT" 2>/dev/null || true

    if command -v fuser >/dev/null 2>&1; then
      if [[ "${ZRM_KILL_MNT_HOLDERS:-0}" == "1" ]]; then
        log "Force-killing $MNT holders (ZRM_KILL_MNT_HOLDERS=1)"
        fuser -km "$MNT" 2>/dev/null || true
      else
        log "Skipping force-kill of $MNT holders (set ZRM_KILL_MNT_HOLDERS=1 to enable)"
      fi
    fi

    zpool export -f "$POOL" 2>/dev/null && return 0
    sleep 1
  done

  return 1
}

cleanup() {
  set +e
  force_release_pool || true
}
trap cleanup EXIT

############################################

# CHECKS

############################################

[ "$(id -u)" -eq 0 ] || die "Run as root"
[ -d /sys/firmware/efi ] || die "Must boot in UEFI mode"
mkdir -p /dev/pts
mountpoint -q /dev/pts || mount -t devpts devpts /dev/pts -o gid=5,mode=620,ptmxmode=000

if (( REPAIR_CHROOT == 0 )); then
  for disk in "$DISK1" "$DISK2"; do
    [ -b "$disk" ] || die "$disk is not a block device"
    [ "$(lsblk -dn -o TYPE "$disk")" = "disk" ] || die "$disk is not a writable disk device"
  done
  collect_nic_drivers
  collect_boot_network
  detect_install_timezone
  log "Matched install disks: $DISK1 and $DISK2"
  print_matched_disks
  if (( DRY_RUN == 1 )); then
    exit 0
  fi
fi

if (( REPAIR_CHROOT == 0 )); then
  ############################################

  # FIX APT (DEBIAN LIVE)

  ############################################

  ensure_time_sync

  log "Resetting APT sources"

  rm -rf /etc/apt/sources.list*
  rm -rf /etc/apt/sources.list.d/* || true

  cat > /etc/apt/sources.list <<EOF_APT
 deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
 deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
 deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF_APT

  apt-get clean
  auto_preseed_zfs
  apt-get update

  ############################################

  # INSTALL TOOLS

  ############################################

  log "Installing required tools"

  "${APT_INSTALL[@]}" debootstrap gdisk dosfstools rsync efibootmgr curl ca-certificates

  ############################################

  # LOAD ZFS MODULE (LIVE ISO MUST PROVIDE IT)

  ############################################

  ensure_live_zfs_tools

  ############################################

  # WIPE + PARTITION

  ############################################

  log "Wiping disks"

  if zpool list "$POOL" >/dev/null 2>&1; then
    log "Pool $POOL is active; attempting cleanup"
    force_release_pool || die "Pool $POOL is busy; reboot the live environment and retry from a clean ISO session"
  fi
  zpool labelclear -f "$ZFS1" 2>/dev/null || true
  zpool labelclear -f "$ZFS2" 2>/dev/null || true

  wipefs -a "$DISK1" || true
  wipefs -a "$DISK2" || true
  wipefs -a "$ZFS1" 2>/dev/null || true
  wipefs -a "$ZFS2" 2>/dev/null || true

  sgdisk --zap-all "$DISK1"
  sgdisk --zap-all "$DISK2"

  if command -v udevadm >/dev/null 2>&1; then
    udevadm settle || true
  fi
  partprobe "$DISK1" || true
  partprobe "$DISK2" || true
  sleep 2

  sgdisk -n1:1M:+512M -t1:EF00 "$DISK1"
  sgdisk -n1:1M:+512M -t1:EF00 "$DISK2"

  sgdisk -n2:0:0 -t2:BF00 "$DISK1"
  sgdisk -n2:0:0 -t2:BF00 "$DISK2"

  if command -v udevadm >/dev/null 2>&1; then
    udevadm settle || true
  fi
  partprobe "$DISK1" || true
  partprobe "$DISK2" || true
  sleep 2
  [ -b "$ZFS1" ] || die "Expected partition $ZFS1 was not created"
  [ -b "$ZFS2" ] || die "Expected partition $ZFS2 was not created"
  zpool labelclear -f "$ZFS1" 2>/dev/null || true
  zpool labelclear -f "$ZFS2" 2>/dev/null || true
  if zpool status "$POOL" >/dev/null 2>&1; then
    log "Pool $POOL still appears active after wipe; retrying cleanup"
    force_release_pool || die "Pool $POOL is still active after disk wipe; reboot the live environment before retrying"
  fi

  ############################################

  # CREATE ZFS POOL

  ############################################

  log "Creating ZFS pool"

  zpool create -f \
    -o ashift=12 \
    -O compression=lz4 \
    -O atime=off \
    -O mountpoint=none \
    "$POOL" mirror "$ZFS1" "$ZFS2"

  zpool export "$POOL"
  zpool import -N -R "$MNT" "$POOL"

  ############################################

  # DATASETS

  ############################################

  log "Creating datasets"

  zfs create -o mountpoint=none "$POOL/ROOT"
  zfs create -o mountpoint=/ -o canmount=noauto "$ROOT_DS"

  for ds in \
    home srv tmp \
    opt opt/local \
    usr-local usr-src
  do
    zfs create -o mountpoint="/$ds" "$POOL/$ds"
  done

  zpool set bootfs="$ROOT_DS" "$POOL"

  ############################################

  # MOUNT

  ############################################

  mkdir -p "$MNT"
  zfs mount "$ROOT_DS"
  zfs mount -a
  ensure_target_datasets_mounted

  ############################################

  # DEBOOTSTRAP (CONFIRMED WORKING)

  ############################################

  log "Bootstrapping Debian"

  debootstrap "$RELEASE" "$MNT" http://deb.debian.org/debian

  [ -f "$MNT/etc/debian_version" ] || die "debootstrap failed"

  ############################################

  # BIND MOUNTS

  ############################################

  mount --rbind /dev "$MNT/dev"
  mount --make-rslave "$MNT/dev"
  mount --rbind /proc "$MNT/proc"
  mount --make-rslave "$MNT/proc"
  mount --rbind /sys "$MNT/sys"
  mount --make-rslave "$MNT/sys"

  collect_nic_drivers
  collect_boot_network

fi

############################################

# CHROOT CONFIG

############################################

run_target_chroot_config() {
local nic_drivers_env="${NIC_DRIVERS[*]:-}"
chroot "$MNT" /usr/bin/env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root TERM="${TERM:-dumb}" LANG=C.UTF-8 LC_ALL=C.UTF-8 LANGUAGE= RELEASE="$RELEASE" INSTALL_HOSTNAME="$HOSTNAME" INSTALL_TIMEZONE="$INSTALL_TIMEZONE" ROOT_PASSWORD="$ROOT_PASSWORD" ESP1="$ESP1" ESP2="$ESP2" DISK1="$DISK1" DISK2="$DISK2" NIC_DRIVERS="$nic_drivers_env" BOOT_NET_IFACE="$BOOT_NET_IFACE" BOOT_NET_MAC="$BOOT_NET_MAC" POOL="$POOL" SKIP_ESP_FORMAT="${SKIP_ESP_FORMAT:-0}" /bin/bash <<'EOF_CHROOT'
set -e
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8 LC_ALL=C.UTF-8 LANGUAGE=
mkdir -p /var/log
CHROOT_LOG=${ZRM_CHROOT_LOG:-/var/log/zfs-root-menu-chroot.log}
exec > >(tee -a "$CHROOT_LOG") 2>&1
printf 'Logging to %s\n' "$CHROOT_LOG"

cat > /etc/apt/sources.list <<APT_CHROOT
deb http://deb.debian.org/debian ${RELEASE} main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${RELEASE}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${RELEASE}-security main contrib non-free non-free-firmware
APT_CHROOT

if command -v debconf-set-selections >/dev/null 2>&1; then
  debconf-set-selections <<'EOF_DEBCONF'
zfs-dkms zfs-dkms/note-incompatible-licenses note
zfs-dkms zfs-dkms/stop build failure boolean true
EOF_DEBCONF
fi

if [[ -n "${INSTALL_TIMEZONE:-}" && -e "/usr/share/zoneinfo/${INSTALL_TIMEZONE}" ]]; then
  ln -snf "/usr/share/zoneinfo/${INSTALL_TIMEZONE}" /etc/localtime
  printf '%s\n' "${INSTALL_TIMEZONE}" > /etc/timezone
fi

mkdir -p /tmp
chmod 1777 /tmp
mkdir -p /var/lib/dpkg /var/lib/apt/lists/partial /var/cache/apt/archives/partial
touch /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend

apt-get update

apt-get install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold console-setup locales zstd apparmor ca-certificates dracut dracut-config-generic linux-image-amd64 linux-headers-amd64 build-essential dkms zfs-dkms zfsutils-linux zfs-dracut openssh-server openssh-client efibootmgr dosfstools rsync curl neovim zsh git systemd systemd-sysv systemd-boot-efi dbus dbus-broker iproute2 isc-dhcp-client iputils-arping
apt-get -f install -y
dpkg --configure -a
if command -v locale-gen >/dev/null 2>&1; then
  printf '%s\n' 'en_US.UTF-8 UTF-8' > /etc/locale.gen
  locale-gen en_US.UTF-8
fi
if command -v update-locale >/dev/null 2>&1; then
  update-locale LANG=en_US.UTF-8 LC_TIME=en_US.UTF-8 LC_NUMERIC=en_US.UTF-8 || true
fi
export LANG=en_US.UTF-8 LC_TIME=en_US.UTF-8 LC_NUMERIC=en_US.UTF-8
printf 'REMAKE_INITRD=yes\n' > /etc/dkms/zfs.conf
TARGET_KERNEL=$(readlink -f /vmlinuz | sed 's|.*/vmlinuz-||')
if command -v dkms >/dev/null 2>&1 && [[ ! -e "/lib/modules/${TARGET_KERNEL}/updates/dkms/zfs.ko" && ! -e "/lib/modules/${TARGET_KERNEL}/updates/dkms/zfs.ko.xz" ]]; then
  dkms autoinstall
fi
INITRD_PATH="/boot/initrd.img-${TARGET_KERNEL}"
if command -v dracut >/dev/null 2>&1; then
  dracut --force "$INITRD_PATH" "$TARGET_KERNEL"
else
  echo "dracut is not installed in the target" >&2
  exit 1
fi
[ -e "$INITRD_PATH" ] || { echo "missing $INITRD_PATH" >&2; exit 1; }
if command -v lsinitrd >/dev/null 2>&1; then
  lsinitrd "$INITRD_PATH" | grep -Eq '(^|/)(zfs|zpool|mount\.zfs|vdev_id|hostid)($|/)' || { echo "$INITRD_PATH does not contain ZFS support" >&2; exit 1; }
elif command -v lsinitramfs >/dev/null 2>&1; then
  lsinitramfs "$INITRD_PATH" | grep -Eq '(^|/)(zfs|zpool|mount\.zfs|vdev_id|hostid)($|/)' || { echo "$INITRD_PATH does not contain ZFS support" >&2; exit 1; }
else
  echo "Neither lsinitrd nor lsinitramfs is available to validate $INITRD_PATH" >&2
  exit 1
fi
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 LANGUAGE=
TARGET_HOSTID=""
if [[ -s /etc/hostid ]]; then
  TARGET_HOSTID=$(od -An -N4 -tx4 /etc/hostid | tr -d '[:space:]')
fi
if [[ -z "$TARGET_HOSTID" ]]; then
  TARGET_HOSTID=$(od -An -N4 -tx4 /dev/urandom | tr -d '[:space:]')
  if command -v zgenhostid >/dev/null 2>&1; then
    zgenhostid -f 0x${TARGET_HOSTID}
  else
    printf '%08x' "0x${TARGET_HOSTID}" | xxd -r -p > /etc/hostid
  fi
fi
zpool set cachefile=/etc/zfs/zpool.cache "$POOL"
zfs set org.zfsbootmenu:commandline="loglevel=7 spl_hostid=${TARGET_HOSTID} zbm.timeout=10 console=ttyS0,115200n8 console=tty0" "$POOL/ROOT"

echo "$INSTALL_HOSTNAME" > /etc/hostname

############################################

# NETWORK

############################################

mkdir -p /etc/systemd/network
cat > /etc/systemd/network/20-wired.network <<NET
[Match]
Name=en*

[Network]
DHCP=yes
NET

systemctl enable systemd-networkd
systemctl enable serial-getty@ttyS0.service
for unit in zfs-import-cache.service zfs-mount.service zfs.target; do
  if systemctl list-unit-files "$unit" >/dev/null 2>&1; then
    systemctl enable "$unit" || true
  fi
done

############################################

# EFI SETUP

############################################

mkdir -p /boot/efi /boot/efi2

if [[ "${SKIP_ESP_FORMAT:-0}" != "1" ]]; then
  command -v mkfs.vfat >/dev/null 2>&1 || apt-get install -y dosfstools
  mkfs.vfat "$ESP1"
  mkfs.vfat "$ESP2"
fi

mountpoint -q /boot/efi || mount "$ESP1" /boot/efi
ESP1_UUID=$(blkid -s UUID -o value "$ESP1" 2>/dev/null || true)
ESP2_UUID=$(blkid -s UUID -o value "$ESP2" 2>/dev/null || true)
cat > /etc/fstab <<FSTAB
# / is managed by ZFS
FSTAB
if [[ -n "$ESP1_UUID" ]]; then
  printf 'UUID=%s /boot/efi vfat umask=0077 0 1\n' "$ESP1_UUID" >> /etc/fstab
fi
if [[ -n "$ESP2_UUID" ]]; then
  printf 'UUID=%s /boot/efi2 vfat noauto,umask=0077 0 0\n' "$ESP2_UUID" >> /etc/fstab
fi

############################################

# ZFSBOOTMENU

############################################

mkdir -p /boot/efi/EFI/ZBM /boot/efi/EFI/BOOT
curl --retry 5 --retry-delay 2 --retry-connrefused -fL -o /boot/efi/EFI/ZBM/VMLINUZ.EFI https://get.zfsbootmenu.org/efi
[ -s /boot/efi/EFI/ZBM/VMLINUZ.EFI ] || { echo "Downloaded ZBM EFI payload is missing or empty" >&2; exit 1; }
cp /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI
cp /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/BOOT/BOOTX64.EFI
for path in /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI /boot/efi/EFI/BOOT/BOOTX64.EFI; do
  [ -s "$path" ] || { echo "Missing EFI payload on primary ESP: $path" >&2; exit 1; }
done

############################################

# EFI SYNC

############################################

cat > /usr/local/sbin/sync-efi.sh <<SYNC
#!/usr/bin/env bash
set -euo pipefail
mountpoint -q /boot/efi2 || mount "$ESP2" /boot/efi2
rsync -a --delete /boot/efi/ /boot/efi2/
sync
if mountpoint -q /boot/efi2; then
  umount /boot/efi2 2>/dev/null || umount -l /boot/efi2 2>/dev/null || true
fi
SYNC

chmod +x /usr/local/sbin/sync-efi.sh

cat > /etc/systemd/system/efi-sync.service <<SERVICE
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sync-efi.sh
SERVICE

cat > /etc/systemd/system/efi-sync.path <<PATH
[Path]
PathChanged=/boot/efi/EFI/ZBM
[Install]
WantedBy=multi-user.target
PATH

/usr/local/sbin/sync-efi.sh
mountpoint -q /boot/efi2 || mount "$ESP2" /boot/efi2
for path in /boot/efi2/EFI/ZBM/VMLINUZ.EFI /boot/efi2/EFI/ZBM/VMLINUZ-BACKUP.EFI /boot/efi2/EFI/BOOT/BOOTX64.EFI; do
  [ -s "$path" ] || { echo "Missing EFI payload on mirror ESP: $path" >&2; exit 1; }
done
umount /boot/efi2 2>/dev/null || umount -l /boot/efi2 2>/dev/null || true
systemctl enable efi-sync.path

############################################

# EFI BOOT ENTRIES

############################################

while read -r id; do
  [[ -n "$id" ]] || continue
  efibootmgr -b "$id" -B >/dev/null 2>&1 || true
done < <(efibootmgr | awk '/ZFSBootMenu/{sub(/^Boot/,"",$1); sub(/\*/,"",$1); print $1}')
efibootmgr -c -d "$DISK1" -p 1 -L "ZFSBootMenu" -l '\EFI\ZBM\VMLINUZ.EFI'
efibootmgr -c -d "$DISK2" -p 1 -L "ZFSBootMenu Mirror" -l '\EFI\ZBM\VMLINUZ-BACKUP.EFI'

############################################

# ROOT PASSWORD + SSH ACCESS

############################################

ROOT_PASSWORD=${ROOT_PASSWORD:-root}
printf 'root:%s\n' "${ROOT_PASSWORD}" | chpasswd
passwd -u root >/dev/null 2>&1 || true

install -d -m 700 /root/.ssh
if [[ -s /root/.ssh/authorized_keys ]]; then
  chmod 600 /root/.ssh/authorized_keys
fi
cat > /etc/ssh/sshd_config.d/99-zfs-root-menu.conf <<SSHD
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
SSHD
systemctl enable ssh.service || true

if [[ ! -d /root/.oh-my-zsh ]]; then
  git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git /root/.oh-my-zsh
fi
ROOT_ZSH_PLUGINS="git"
if [[ -f /root/.oh-my-zsh/plugins/zfs/zfs.plugin.zsh ]]; then
  ROOT_ZSH_PLUGINS="git zfs"
fi
cat > /root/.zshrc <<ZSHRC
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"
plugins=($ROOT_ZSH_PLUGINS)
source $ZSH/oh-my-zsh.sh
ZSHRC
chown root:root /root/.zshrc
chmod 600 /root/.zshrc
chsh -s /usr/bin/zsh root || true

cat > /usr/local/sbin/zfs-useradd <<ZFSUSERADD
#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 1 ]]; then
  echo "Usage: zfs-useradd <username>" >&2
  exit 1
fi
USER_NAME="$1"
POOL_NAME="$POOL"
HOME_DS="${POOL_NAME}/home/${USER_NAME}"
HOME_DIR="/home/${USER_NAME}"
if ! zfs list "$HOME_DS" >/dev/null 2>&1; then
  zfs create -o mountpoint="$HOME_DIR" "$HOME_DS"
fi
if ! id "$USER_NAME" >/dev/null 2>&1; then
  useradd -m -d "$HOME_DIR" -s /usr/bin/zsh "$USER_NAME"
fi
chown -R "$USER_NAME:$USER_NAME" "$HOME_DIR"
passwd "$USER_NAME"
ZFSUSERADD
chmod 755 /usr/local/sbin/zfs-useradd

for dir in /var/lib/dpkg /var/lib/apt/lists/partial /var/cache/apt/archives/partial /var/log /var/tmp /tmp /run/lock; do
  install -d "$dir"
done
chmod 1777 /tmp /var/tmp
[ -e /var/lib/dpkg/status ] || { echo "Missing /var/lib/dpkg/status; target root is not package-manageable" >&2; exit 1; }
# no per-dataset mount checks needed in simplified layout
EOF_CHROOT
}

if (( REPAIR_CHROOT == 1 )); then
  prepare_existing_target
  log "Matched existing install disks: $DISK1 and $DISK2"
  print_matched_disks
  SKIP_ESP_FORMAT=1
else
  SKIP_ESP_FORMAT=0
fi
ensure_target_datasets_mounted
stage_target_root_authorized_keys
log "Running target chroot configuration"
run_target_chroot_config
log "Target chroot configuration complete"

############################################

# FINALIZE

############################################

if zpool list "$POOL" >/dev/null 2>&1; then
  if zpool export "$POOL"; then
    log "Exported pool $POOL"
  else
    log "Initial export of $POOL failed; retrying cleanup"
    force_release_pool || true
    if zpool list "$POOL" >/dev/null 2>&1; then
      log "WARNING: Pool $POOL is still active; continuing without export"
    else
      log "Exported pool $POOL after cleanup retry"
    fi
  fi
else
  log "Pool $POOL already exported"
fi

log "DONE - REBOOT NOW"
