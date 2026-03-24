#!/usr/bin/env bash
set -euo pipefail

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
      DISK1="/dev/$pkname"
      ZFS1="$member"
      ESP1="${DISK1}1"
    else
      DISK2="/dev/$pkname"
      ZFS2="$member"
      ESP2="${DISK2}1"
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
  DISK1="${DISKS[0]}"
  DISK2="${DISKS[1]}"
  ESP1="${DISK1}1"
  ESP2="${DISK2}1"
  ZFS1="${DISK1}2"
  ZFS2="${DISK2}2"
fi

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

  if ! zpool list "$POOL" >/dev/null 2>&1; then
    zpool import -N -R "$MNT" "$POOL" >/dev/null 2>&1       || zpool import -f -N -R "$MNT" "$POOL" >/dev/null 2>&1       || zpool import -N -R "$MNT" >/dev/null 2>&1       || zpool import -f -N -R "$MNT" >/dev/null 2>&1       || die "Could not import existing pool $POOL"
  fi

  infer_existing_layout
  mkdir -p "$MNT"
  zfs mount "$ROOT_DS" 2>/dev/null || true
  zfs mount -a 2>/dev/null || true

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

cleanup() {
  set +e
  zfs unmount -a 2>/dev/null || true
  umount -Rl "$MNT" 2>/dev/null || true
  zpool export -f "$POOL" 2>/dev/null || true
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

  zpool export -f "$POOL" 2>/dev/null || true
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
    die "Pool $POOL is still active after disk wipe; export it cleanly or reboot the live environment before retrying"
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
    home root srv tmp \
    var var/log var/tmp var/cache var/lib var/spool var/www \
    opt opt/local \
    usr-local usr-src \
    boot
  do
    zfs create -o mountpoint="/$ds" "$POOL/$ds"
  done

  zpool set bootfs="$ROOT_DS" "$POOL"

  ############################################

  # MOUNT

  ############################################

  mkdir -p "$MNT"
  zfs mount "$ROOT_DS"
  zfs mount -a || true

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

  ############################################

  # REMOTE ZBM ACCESS PREP

  ############################################

  collect_nic_drivers
  collect_boot_network

  LIVE_AUTHORIZED_KEYS=""
  for candidate in /root/.ssh/authorized_keys /home/user/.ssh/authorized_keys; do
    if [[ -f "$candidate" ]]; then
      LIVE_AUTHORIZED_KEYS="$candidate"
      break
    fi
  done
  if [[ -n "$LIVE_AUTHORIZED_KEYS" ]]; then
    install -d -m 700 "$MNT/etc/dropbear"
    install -m 600 "$LIVE_AUTHORIZED_KEYS" "$MNT/etc/dropbear/root_key"
  fi

fi

############################################

# CHROOT CONFIG

############################################

run_target_chroot_config() {
local nic_drivers_env="${NIC_DRIVERS[*]:-}"
chroot "$MNT" /usr/bin/env RELEASE="$RELEASE" INSTALL_HOSTNAME="$HOSTNAME" ESP1="$ESP1" ESP2="$ESP2" DISK1="$DISK1" DISK2="$DISK2" NIC_DRIVERS="$nic_drivers_env" BOOT_NET_IFACE="$BOOT_NET_IFACE" BOOT_NET_MAC="$BOOT_NET_MAC" SKIP_ESP_FORMAT="${SKIP_ESP_FORMAT:-0}" /bin/bash <<'EOF_CHROOT'
set -e
export DEBIAN_FRONTEND=noninteractive

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

mkdir -p /tmp
chmod 1777 /tmp
mkdir -p /var/lib/dpkg /var/lib/apt/lists/partial /var/cache/apt/archives/partial
touch /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend

apt-get update

apt-get install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold initramfs-tools linux-image-amd64 linux-headers-amd64 build-essential dkms zfs-dkms zfsutils-linux zfs-initramfs openssh-server openssh-client efibootmgr dosfstools rsync curl git fzf mbuffer kexec-tools libsort-versions-perl libboolean-perl libyaml-pp-perl systemd systemd-sysv systemd-boot-efi dbus dbus-broker iproute2 isc-dhcp-client iputils-arping bsdextrautils dropbear libblkid-dev pkgconf libkmod-dev libudev-dev libsystemd-dev asciidoc xmlto docbook-xml docbook-xsl
apt-get -f install -y
dpkg --configure -a
printf 'REMAKE_INITRD=yes\n' > /etc/dkms/zfs.conf
TARGET_KERNEL=$(readlink -f /vmlinuz | sed 's|.*/vmlinuz-||')
if command -v dkms >/dev/null 2>&1 && [[ ! -e "/lib/modules/${TARGET_KERNEL}/updates/dkms/zfs.ko" && ! -e "/lib/modules/${TARGET_KERNEL}/updates/dkms/zfs.ko.xz" ]]; then
  dkms autoinstall
fi
update-initramfs -u -k all
INITRD_PATH="/boot/initrd.img-${TARGET_KERNEL}"
[ -e "$INITRD_PATH" ] || { echo "missing $INITRD_PATH" >&2; exit 1; }
lsinitramfs "$INITRD_PATH" | grep -Eq '(^|/)(zfs|zpool|mount\.zfs|vdev_id|hostid)($|/)' || { echo "$INITRD_PATH does not contain ZFS support" >&2; exit 1; }
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
zpool set cachefile=/etc/zfs/zpool.cache zroot
zfs set org.zfsbootmenu:commandline="loglevel=7 spl_hostid=${TARGET_HOSTID} console=ttyS0,115200n8 console=tty0" zroot/ROOT

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

############################################

# ZFSBOOTMENU

############################################

rm -rf /usr/src/dracut /usr/src/dracut-crypt-ssh /usr/src/zfsbootmenu
rm -f /usr/lib/systemd/system/dracut-shutdown-onfailure.service       /usr/lib/systemd/system/dracut-shutdown.service       /usr/lib/systemd/system/sysinit.target.wants/dracut-shutdown.service       /usr/lib/systemd/system/initrd.target.wants/dracut-cmdline.service       /usr/lib/systemd/system/initrd.target.wants/dracut-initqueue.service       /usr/lib/systemd/system/initrd.target.wants/dracut-mount.service       /usr/lib/systemd/system/initrd.target.wants/dracut-pre-mount.service       /usr/lib/systemd/system/initrd.target.wants/dracut-pre-pivot.service       /usr/lib/systemd/system/initrd.target.wants/dracut-pre-trigger.service       /usr/lib/systemd/system/initrd.target.wants/dracut-pre-udev.service
mkdir -p /boot/efi/EFI/ZBM /boot/efi/EFI/BOOT /etc/zfsbootmenu /etc/zfsbootmenu/dracut.conf.d /etc/cmdline.d /etc/dropbear /usr/src/zfsbootmenu /usr/src/dracut-crypt-ssh /root/.ssh

for keytype in rsa ecdsa; do
  if [[ ! -f "/etc/dropbear/ssh_host_${keytype}_key" ]]; then
    ssh-keygen -q -g -N "" -m PEM -t "$keytype" -f "/etc/dropbear/ssh_host_${keytype}_key"
  fi
done
if [[ -f /etc/dropbear/root_key ]]; then
  install -m 600 /etc/dropbear/root_key /root/.ssh/authorized_keys
fi

git clone --depth=1 https://github.com/dracutdevs/dracut.git /usr/src/dracut
( cd /usr/src/dracut && ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --systemdsystemunitdir=/usr/lib/systemd/system --systemdutildir=/usr/lib/systemd && make && make install )
git clone --depth=1 https://github.com/dracut-crypt-ssh/dracut-crypt-ssh.git /usr/src/dracut-crypt-ssh
( cd /usr/src/dracut-crypt-ssh && ./configure --prefix=/usr && make && make install )

curl -L https://get.zfsbootmenu.org/source | tar -zxv --strip-components=1 -C /usr/src/zfsbootmenu -f -
make -C /usr/src/zfsbootmenu core dracut

cat > /etc/zfsbootmenu/config.yaml <<CFG
Global:
  ManageImages: true
  BootMountPoint: /boot/efi
Components:
  Enabled: false
EFI:
  Enabled: true
  ImageDir: /boot/efi/EFI/ZBM
  Versions: false
Kernel:
  CommandLine: loglevel=7 rd.debug rd.shell zbm.show spl_hostid=${TARGET_HOSTID} console=ttyS0,115200n8 console=tty0
CFG

COMMON_NET_DRIVERS="virtio virtio_pci virtio_ring virtio_net e1000 e1000e igc igb r8169 tg3 bnxt_en mlx5_core"
ALL_DRIVERS="ahci ata_piix sd_mod virtio_blk virtio_pci ${COMMON_NET_DRIVERS} ${NIC_DRIVERS:-}"
ALL_DRIVERS=$(printf '%s\n' "$ALL_DRIVERS" | xargs -n1 | awk 'NF && !seen[$0]++' | xargs)
RD_DRIVER_PRE=$(printf '%s\n' "$ALL_DRIVERS" | xargs -n1 printf ' rd.driver.pre=%s')
if [[ -n "${BOOT_NET_MAC:-}" ]]; then
  echo "ifname=bootnet:${BOOT_NET_MAC} ip=bootnet:dhcp rd.neednet=1 rd.net.dhcp.retry=1 rd.net.timeout.iflink=30 rd.net.timeout.ifup=30 rd.net.timeout.dhcp=30${RD_DRIVER_PRE}" > /etc/cmdline.d/dracut-network.conf
else
  echo "ip=dhcp rd.neednet=1 rd.net.dhcp.retry=1 rd.net.timeout.iflink=30 rd.net.timeout.ifup=30 rd.net.timeout.dhcp=30${RD_DRIVER_PRE}" > /etc/cmdline.d/dracut-network.conf
fi
cat > /etc/zfsbootmenu/dracut.conf.d/dropbear.conf <<DROPBEAR
add_dracutmodules+=" crypt-ssh "
omit_dracutmodules+=" systemd systemd-initrd dracut-systemd systemd-battery-check systemd-udevd fido2 systemd-cryptsetup systemd-pcrphase systemd-networkd dbus dbus-broker dbus-daemon iscsi nbd nfs "
install_optional_items+=" /etc/cmdline.d/dracut-network.conf "
dropbear_rsa_key=/etc/dropbear/ssh_host_rsa_key
dropbear_ecdsa_key=/etc/dropbear/ssh_host_ecdsa_key
dropbear_acl=/etc/dropbear/root_key
hostonly="no"
add_drivers+=" ${ALL_DRIVERS} "
force_drivers+=" ${ALL_DRIVERS} "
DROPBEAR

generate-zbm
cp /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI
cp /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/BOOT/BOOTX64.EFI

############################################

# EFI SYNC

############################################

cat > /usr/local/sbin/sync-efi.sh <<SYNC
#!/usr/bin/env bash
mount "$ESP2" /boot/efi2 2>/dev/null || true
rsync -a --delete /boot/efi/ /boot/efi2/
umount /boot/efi2 || true
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

systemctl enable efi-sync.path
systemctl start efi-sync.service

############################################

# EFI BOOT ENTRIES

############################################

efibootmgr -c -d "$DISK1" -p 1 -L "ZFSBootMenu" -l '\EFI\ZBM\VMLINUZ.EFI'
efibootmgr -c -d "$DISK2" -p 1 -L "ZFSBootMenu Mirror" -l '\EFI\ZBM\VMLINUZ-BACKUP.EFI'

############################################

# ROOT PASSWORD

############################################

if ! passwd root; then
  echo 'passwd failed; setting default root password to root' >&2
  echo 'root:root' | chpasswd
fi
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
run_target_chroot_config

############################################

# FINALIZE

############################################

zpool export "$POOL"

log "DONE - REBOOT NOW"
