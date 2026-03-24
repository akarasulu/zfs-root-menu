#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd -- "$ROOT_DIR"

./tools/remaster-livecd.sh "$@"
virsh destroy zfs-root-menu >/dev/null 2>&1 || true
virsh undefine zfs-root-menu --nvram >/dev/null 2>&1 || true
qemu-img create -f qcow2 disk1.qcow2 -o preallocation=metadata 20G
qemu-img create -f qcow2 disk2.qcow2 -o preallocation=metadata 20G
cp /usr/share/OVMF/OVMF_VARS.fd "$ROOT_DIR/NVRAM_VARS.fd"
virsh define ./definition.xml
virsh start zfs-root-menu
printf 'Domain started under qemu:///system.\n'
printf 'Serial console: sudo virsh -c qemu:///system console zfs-root-menu\n'
printf 'Live ISO login: user / user\n'
printf 'SSH to the live ISO using the guest IP on your host-access network.\n'
