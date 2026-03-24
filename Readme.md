# Zfs Root Menu

`zfs-root-menu.sh` installs Debian Trixie onto a mirrored two-disk ZFS root and configures ZFSBootMenu to boot the installed environment.

It is destructive. The two matched disks are repartitioned and wiped.

## What It Does

- Matches exactly two target disks by name/model substring and size substring.
- Creates mirrored EFI and ZFS partitions on both disks.
- Creates a mirrored `zroot` pool with common child datasets.
- Bootstraps Debian Trixie into the ZFS root.
- Installs kernel, headers, DKMS, ZFS userspace, `initramfs-tools`, and `zfs-initramfs` inside the target.
- Builds a custom source-built `dracut` + `dracut-crypt-ssh` based ZFSBootMenu image inside the target.
- Configures ZFSBootMenu remote SSH access when an authorized keys file is available in the live environment.
- Creates UEFI boot entries for both ESPs and the fallback path `EFI/BOOT/BOOTX64.EFI`.

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
- `--repair-chroot`: Re-enter an existing install from the live ISO and rebuild the target-side boot stack.
- `--dry-run`: Print matched drives and planned partition devices, then exit without making changes.
- `--help`: Show usage.

## Disk Matching

The script matches disks from `lsblk` using:

- case-insensitive name/model/vendor matching via `--name`
- normalized size matching via `--size`

It requires exactly two matches. If the filter matches fewer or more than two disks, the script exits.

## Non-Interactive Package Installs

APT and DKMS-related package installation are configured to run non-interactively, including ZFS DKMS licensing. Boot-critical target package steps are intentionally strict now; the script should fail rather than continue with a bad initramfs.

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

That fallback `BOOTX64.EFI` path matters for firmware that ignores or loses explicit NVRAM entries.

## ZFSBootMenu SSH Access

The installer builds a custom ZFSBootMenu image inside the target chroot.

When an authorized keys file is available in the live environment, the installer copies it into the target and configures Dropbear-based remote access in the generated ZFSBootMenu image.

Authorized keys source order during install:

- `/root/.ssh/authorized_keys`
- `/home/user/.ssh/authorized_keys`

Expected behavior:

- ZFSBootMenu Dropbear listens on guest port `222`.
- Login is as `root`, not `user`.
- The authorized key must be present in the generated image, or SSH will fail with `Permission denied (publickey)`.

## Remaster Workflow

The repo includes a Trixie-chroot-based remaster workflow.

Host wrapper:

```bash
./tools/remaster-livecd.sh
```

What it does:

- creates or reuses `./.remaster-chroot`
- bootstraps a Debian Trixie remaster environment with `debootstrap`
- installs remaster tools inside that chroot
- runs ISO extraction, customization, and repack entirely inside the Trixie chroot

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
- mounts `devpts` using a systemd mount unit so PTY-dependent tools keep working after boot
- bakes in live-environment ZFS support instead of rebuilding it during installer runtime

Optional SSH public key support:

- pass `--authorized-keys-url URL` to `./tools/remaster-livecd.sh`
- if `--authorized-keys-url` is not provided, the wrapper falls back to `./ssh_id.pub` if that file or symlink resolves to a real host file

If a valid key is available, it is added to:

- `/home/user/.ssh/authorized_keys`

## VM Usage

The successful VM model from development was:

- system libvirt mode, not session mode
- one host-reachable NIC on `host-bridge`
- one separate internet NIC using a real uplink-backed macvtap/macvlan attachment

Important operational notes:

- `setup.sh` redefines the domain from `definition.xml` every run.
- If you are using system libvirt, use `sudo virsh ...` for domain and network inspection.
- The checked-in `definition.xml` must match your actual host network topology. A dead or unmanaged `virbr0` path caused repeated false network failures during development.
- Macvlan/macvtap does not provide host-to-guest communication on the parent NIC path, so keep a separate host-access NIC if you need SSH from the host.

Example build/start:

```bash
sudo ./setup.sh
sudo ./setup.sh --authorized-keys-url file:///home/aok/.ssh/id_rsa.pub
```

Serial console access:

```bash
sudo virsh console zfs-root-menu
```

## Recovery Workflow

When the live ISO is already booted and the target disks already contain an install, rebuild the target-side boot stack with:

```bash
sudo /home/user/zfs-root-menu.sh --repair-chroot
```

Use this after updating `zfs-root-menu.sh` in the live environment when you want to regenerate the target ZFSBootMenu image or target initramfs without repartitioning the disks again.

## Known Pitfalls

- PTYs can break if `/dev`, `/proc`, and `/sys` are bind-mounted into the target chroot without `rslave` propagation controls. This was fixed in the script, but it is the first thing to suspect if `sudo` starts failing after the installer runs.
- ZFSBootMenu networking is sensitive to the actual VM NIC topology. The working path depended on loading the correct NIC drivers early and steering dracut toward the intended boot network.
- A guest NIC can look configured inside the VM while still being unusable if the host-side bridge or libvirt network backing it is dead. Verify both guest routes and host attachment.
- ZFSBootMenu Dropbear access is `root@...`, not `user@...`.
- Hostid mismatches between the pool and `/etc/hostid` can cause confusing import behavior. The installer now writes `spl_hostid=` into the ZFSBootMenu command line to keep pool import consistent.
- The installed system needs a real ZFS-capable initramfs. The script now installs `zfs-initramfs`, regenerates initramfs, and verifies that the generated `initrd.img-*` contains ZFS content before proceeding.
- VM graphics were less reliable than serial during development. Treat `virsh console` as the authoritative early-boot view.

## Notes

For VM serial access, use `virsh console zfs-root-menu`. The installed system enables `serial-getty@ttyS0.service`, and the installer configures both ZFSBootMenu and the final kernel with `console=tty0 console=ttyS0,115200n8`.
