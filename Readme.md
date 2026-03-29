# Zfs Root Menu

`zfs-root-menu.sh` installs Debian Trixie onto a mirrored two-disk ZFS root and configures ZFSBootMenu to boot the installed environment.

It is destructive. The two matched disks are repartitioned and wiped.

## What It Does

- Matches exactly two target disks by name/model substring and size substring.
- Creates mirrored EFI and ZFS partitions on both disks.
- Creates a mirrored `zroot` pool with common child datasets.
- Bootstraps Debian Trixie into the ZFS root.
- Installs kernel, headers, DKMS, ZFS userspace, and Debian Trixie's packaged `dracut`/`zfs-dracut` stack inside the target.
- Installs `neovim`, `zsh`, and `oh-my-zsh` for the target root account with the `zfs` plugin enabled.
- Stages root SSH authorized keys from the live environment when available and enables root SSH access.
- Installs `/usr/local/sbin/zfs-useradd` to create new users with dedicated ZFS home datasets (`zroot/home/<user>`).
- Builds the target initramfs with packaged `dracut` and verifies that the generated image contains ZFS support.
- Installs the upstream prebuilt ZFSBootMenu UEFI image instead of building ZFSBootMenu from source.
- Does not enable pre-boot networking or Dropbear SSH in ZFSBootMenu.
- Creates UEFI boot entries for both ESPs and the fallback path `EFI/BOOT/BOOTX64.EFI`.
- Deduplicates old `ZFSBootMenu` NVRAM entries before creating new ones.

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

## Verification (Checkpoint)

After installer completion, run one command:

```bash
sudo ./verify-install.sh
```

Expected result:

- `RESULT: PASS`
- `OK: Installer completion marker present`
- `OK: dpkg status present`
- `OK: initrd present under /mnt/boot`
- `OK: root authorized_keys present`
- `OK: ESP1/ESP2 ... payload present`

`verify-install.sh` defaults to the newest installer log in `/tmp` and automatically prints a full debug block when validation fails.

## Disk Matching

The script matches disks from `lsblk` using:

- case-insensitive name/model/vendor matching via `--name`
- normalized size matching via `--size`

It requires exactly two matches. If the filter matches fewer or more than two disks, the script exits.

## Non-Interactive Package Installs

APT and DKMS-related package installation are configured to run non-interactively, including ZFS DKMS licensing. Boot-critical target package steps are intentionally strict now; the script should fail rather than continue with a bad initramfs.

## Password Behavior

The script sets the target root password noninteractively. By default it uses:

```text
root
```

You can override that by exporting `ROOT_PASSWORD` before running the installer.

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

The installer does not configure Dropbear or pre-boot SSH for ZFSBootMenu.
Root SSH key staging applies to the installed system (`/root/.ssh/authorized_keys`), sourced from live environment files when available:

- `/root/.ssh/authorized_keys`
- `/home/user/.ssh/authorized_keys`

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

## Ansible Workflow (Stein)

This repo now includes an Ansible role and runtime config to manage the same boot pipeline on `stein`:

- inventory: `inventory.yml`
- config: `ansible.cfg`
- playbook: `playbooks/zfsbootmenu-manage.yml`
- host vars: `host_vars/stein.yml`
- role: `roles/zfsbootmenu_manage`
- role: `roles/sriov_vf_manage`

The role handles:

- building/installing `generate-zbm`
- optional initramfs rebuild using `dracut`
- setting `org.zfsbootmenu:commandline` on ZFS datasets
- mirrored ESP sync using `/usr/local/sbin/sync-efi.sh` and `efi-sync.path`

Playbook execution is wrapped by `roles/zfs_snapshot_guard` to create snapshot envelopes:

- `before-<role>-<timestamp>` before execution
- `after-<role>-<timestamp>` only when changes occur
- if no changes occur, the `before-*` snapshot is removed

### Check pass first

```bash
ansible-playbook playbooks/zfsbootmenu-manage.yml --limit stein --check --diff
```

### Apply run

```bash
ansible-playbook playbooks/zfsbootmenu-manage.yml --limit stein
```

### Extend kernel parameters

Edit `host_vars/stein.yml`:

```yaml
zbm_manage_kernel_commandline_extra_tokens:
  - intel_iommu=on
  - iommu=pt
  - vfio-pci.ids=10de:1b06,10de:10ef
```

Then run check/apply again.

### SR-IOV NIC VF passthrough

`roles/sriov_vf_manage` handles NIC SR-IOV VF lifecycle separately from GPU passthrough:

- keeps PF networking on host drivers (no PF binding to `vfio-pci`)
- creates VFs via `sriov_numvfs`
- binds only selected VF indexes to `vfio-pci`
- persists lifecycle via `sriov-vf-manage.service`

Current `host_vars/stein.yml` uses explicit PF interface configs with per-PF VF counts:

```yaml
sriov_vf_manage_enable: true
sriov_vf_manage_manage_all_capable_pfs: false
sriov_vf_manage_pf_configs:
  - interface: eno1
    numvfs: 4
    bind_all_vfs: true
  - interface: eno2
    numvfs: 4
    bind_all_vfs: true
  - interface: eno3
    numvfs: 0
    bind_all_vfs: true
  - interface: eno4
    numvfs: 0
    bind_all_vfs: true
  - interface: enp137s0f0
    numvfs: 4
    bind_all_vfs: true
  - interface: enp137s0f1
    numvfs: 0
    bind_all_vfs: true
```

Detailed operational runbook:

- `docs/ansible-zbm-role-runbook.md`
- `docs/role-zfs_snapshot_guard.md`
- `docs/role-zfsbootmenu_manage.md`
- `docs/role-sriov_vf_manage.md`
- `docs/sriov-vf-stein-rollout-summary.md`

The latest stein rollout details (design choices, apply/reboot validation, and final state) are documented in:

- `docs/sriov-vf-stein-rollout-summary.md`

### Compare against snapshot

Find latest baseline snapshot:

```bash
ssh root@stein 'zfs list -H -t snapshot -o name -s creation | grep "zroot@pre-vfio-passthru-" | tail -n1'
```

Diff current root dataset against that snapshot:

```bash
ssh root@stein 'SNAP_TAG=$(zfs list -H -t snapshot -o name -s creation | sed -n "s#^zroot@\\(pre-vfio-passthru-.*\\)#\\1#p" | tail -n1); zfs diff -FH zroot/ROOT/trixie@"$SNAP_TAG"'
```

## Known Pitfalls

- PTYs can break if `/dev`, `/proc`, and `/sys` are bind-mounted into the target chroot without `rslave` propagation controls. This was fixed in the script, but it is the first thing to suspect if `sudo` starts failing after the installer runs.
- A guest NIC can look configured inside the VM while still being unusable if the host-side bridge or libvirt network backing it is dead. Verify both guest routes and host attachment.
- Hostid mismatches between the pool and `/etc/hostid` can cause confusing import behavior. The installer now writes `spl_hostid=` into the ZFSBootMenu command line to keep pool import consistent.
- The installed system needs a real ZFS-capable initramfs. The script installs packaged `dracut` and `zfs-dracut`, rebuilds `initrd.img-*`, and verifies that the generated image contains ZFS content before proceeding.
- VM graphics were less reliable than serial during development. Treat `virsh console` as the authoritative early-boot view.
- Final `zpool export` can fail in a busy live session; installer completion is decided by install/verification state, not export success alone.

## Notes

For VM serial access, use `virsh console zfs-root-menu`. The installed system enables `serial-getty@ttyS0.service`, and the installer configures both ZFSBootMenu and the final kernel with `console=tty0 console=ttyS0,115200n8`.
