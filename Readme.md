# Zfs Root Menu

`zfs-root-menu.sh` installs Debian Trixie onto a mirrored two-disk ZFS root and configures ZFSBootMenu for booting the installed environment.

It is destructive. The matched disks are repartitioned and wiped.

<!-- TODO:

Why are we building the ZFS module twice in the zfs-root-menu.sh script now that we are adding zfs to the ISO during remastering?

  - can't we just check if it is installed in the live environment and skip the first build if it is?
  - likewise in --repair-chroot mode can't we just chroot and check if the installed system's ZFS module is already built before trying to build it again?

-->

## What It Does

- Matches exactly two target disks by name/model substring and size substring.
- Creates mirrored EFI and ZFS partitions on both disks.
- Creates a mirrored `zroot` pool.
- Creates the root and common child datasets.
- Bootstraps Debian Trixie into the ZFS root.
- Installs kernel, headers, DKMS, ZFS userspace, `dracut`, and `zfs-dracut` inside the target system.
- Builds a custom ZFSBootMenu EFI image locally inside the target system, with fallback UEFI path `EFI/BOOT/BOOTX64.EFI`.
- Configures ZFSBootMenu remote SSH access when an authorized_keys file is available in the live environment.
- Creates UEFI boot entries for both ESPs.

## Requirements

- Run as `root`.
- Boot the installer environment in UEFI mode.
- Provide exactly two matching writable disks.
- Expect all data on those disks to be destroyed.

## Installer Usage

Dry-run first to confirm the correct drives are selected:

```bash
sudo ./zfs-root-menu.sh --name 'QEMU HARDDISK' --size '20 GiB' --dry-run
```

Run the actual install:

```bash
sudo ./zfs-root-menu.sh --name 'QEMU HARDDISK' --size '20 GiB'
```

General form:

```bash
sudo ./zfs-root-menu.sh --name STRING --size STRING [options]
```

Options:

- `--name STRING`: Required model/vendor/name substring filter.
- `--size STRING`: Required size substring filter.
- `--pool NAME`: ZFS pool name. Default: `zroot`.
- `--hostname NAME`: Target hostname. Default: `stein`.
- `--release NAME`: Debian release. Default: `trixie`.
- `--mountpoint PATH`: Temporary install mountpoint. Default: `/mnt`.
- `--dry-run`: Print matched drives and planned partition devices, then exit without making changes.
- `--help`: Show usage.

## Disk Matching

The script matches disks from `lsblk` using:

- case-insensitive name/model/vendor matching via `--name`
- normalized size matching via `--size`

It requires exactly two matches. If the filter matches fewer or more than two disks, the script exits.

## Non-Interactive Package Installs

APT and DKMS-related package installation are configured to run non-interactively, including the ZFS DKMS license prompt handling, both in the live environment and inside the target chroot.

The final password step is still intended to be interactive.

## Password Behavior

At the end of the install, the script tries:

```bash
passwd root
```

If that fails, for example because the script is being run over SSH without a usable TTY, it falls back to setting the root password to:

```text
root
```

## UEFI Boot Behavior

The installer writes ZFSBootMenu to:

- `\EFI\ZBM\VMLINUZ.EFI`
- `\EFI\ZBM\VMLINUZ-BACKUP.EFI`
- `\EFI\BOOT\BOOTX64.EFI`

That fallback `BOOTX64.EFI` path is important for firmware that ignores or loses the explicit NVRAM boot entry.

## ZFSBootMenu SSH Access

The installer now builds a custom ZFSBootMenu image inside the target chroot instead of downloading a generic prebuilt EFI image.

When an authorized keys file is available in the live environment, the installer copies it into the target and configures Dropbear-based remote access in the generated ZFSBootMenu image.

Authorized keys source order during install:

- `/root/.ssh/authorized_keys`
- `/home/user/.ssh/authorized_keys`

This is intended to make the same SSH key you used for the remastered live ISO available for remote access to ZFSBootMenu.

The generated image is configured with network bring-up via DHCP and includes the `crypt-ssh` dracut module.

Expected remote-access behavior:

- SSH into ZFSBootMenu using your public key
- from the remote shell, launch the menu with `zfsbootmenu` if needed
- the remote-access port is determined by the bundled Dropbear/dracut setup and is typically `222`

## Remaster Workflow

The repo includes a Trixie-chroot-based remaster workflow that embeds the installer into a Debian live ISO instead of relying on the host toolchain for the actual remastering steps.

Host wrapper:

```bash
./tools/remaster-livecd.sh
```

What it does:

- creates or reuses `./.remaster-chroot`
- bootstraps a Debian Trixie remaster environment with `debootstrap`
- installs remaster tools inside that chroot
- runs the actual ISO extraction, customization, and repack entirely inside the Trixie chroot

The wrapper looks for the first `debian-live-*.iso` file or symlink in the repo root.

If that ISO is missing, it can download it automatically. By default it derives an official Debian archive URL from the ISO filename. You can override that with `SOURCE_ISO_URL` or `--source-iso-url`.

Examples:

```bash
sudo ./tools/remaster-livecd.sh
sudo ./tools/remaster-livecd.sh --refresh-chroot
sudo ./tools/remaster-livecd.sh --source-iso ./debian-live-13.4.0-amd64-kde.iso
```

Output:

- `./build/zfs-root-menu-live.iso`

## Live ISO Customization

The remastered live ISO:

- copies `zfs-root-menu.sh` into `/home/user/zfs-root-menu.sh`
- makes it executable
- installs `openssh-server`
- ensures the live `user` account exists
- sets the live `user` password to `user`
- enables `ssh.service`
- enables password authentication for SSH

Optional SSH public key support:

- pass `--authorized-keys-url URL` to `./tools/remaster-livecd.sh`
- if `--authorized-keys-url` is not provided, the wrapper falls back to `./ssh_id.pub` if that file or symlink resolves to a real host file

The wrapper resolves or downloads the key on the host side first, copies it into the remaster chroot, and only then the inner remaster step installs it into the live filesystem.

If a valid key is available, it is added to:

- `/home/user/.ssh/authorized_keys`

## VM Automation

`definition.xml` now points at:

- `/home/aok/Local/Projects/zfs-root-menu/build/zfs-root-menu-live.iso`

`setup.sh` now:

1. builds the remastered live ISO
2. creates the qcow2 disks
3. refreshes the OVMF NVRAM vars file
4. defines the VM with libvirt
5. starts the VM

The libvirt user-network interface forwards:
- host `127.0.0.1:2222` to guest port `22` for the live ISO / installed system SSH
- host `127.0.0.1:2223` to guest port `222` for ZFSBootMenu Dropbear SSH

Examples:

```bash
ssh -p 2222 user@127.0.0.1
ssh -p 2223 root@127.0.0.1
```

Example:

```bash
./setup.sh
./setup.sh --authorized-keys-url https://example.com/id_ed25519.pub
./setup.sh --authorized-keys-url file:///home/aok/.ssh/id_rsa.pub
```

## Notes

- The script contains rerun handling for stale ZFS pool state, but a badly interrupted run can still leave the live environment dirty enough that a reboot is the cleanest recovery.
- If you are testing in a VM, `--dry-run` is the safest first check before any destructive run.
- The remaster workflow is designed so the actual ISO manipulation happens inside the Trixie remaster chroot rather than against host-versioned remaster tools.

For VM serial access, use `virsh console zfs-root-menu`. The installed system enables `serial-getty@ttyS0.service`, and the installer configures both ZFSBootMenu and the final kernel with `console=tty0 console=ttyS0,115200n8`.
