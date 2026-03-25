# Development Path

This file records the working path that emerged during development of this repo. It intentionally leaves out the dead ends except where they are useful as warnings.

## Final Working Shape

The working result was:

- a remastered Debian Trixie live ISO
- a live environment with SSH and baked-in ZFS support
- a destructive installer that creates a mirrored ZFS root on two disks
- a target system that boots through ZFSBootMenu
- no pre-boot SSH in ZFSBootMenu (Dropbear is not configured)
- an installed Debian system that boots its ZFS root using a verified ZFS-capable dracut initramfs

## Working Boot Stack

The current working boot path is:

1. ZFSBootMenu layer
- uses the upstream prebuilt EFI payload from `https://get.zfsbootmenu.org/efi`
- no custom ZFSBootMenu build from source
- no pre-boot Dropbear SSH configuration
- uses `org.zfsbootmenu:commandline` with `spl_hostid=` and serial/console args

2. Installed system layer
- uses Debian packaged `dracut` + `zfs-dracut`
- regenerates `/boot/initrd.img-*`
- verifies generated initramfs contains ZFS-related content before continuing

## Live ISO Path That Worked

The live ISO was remastered inside a Trixie debootstrap chroot rather than with host tools directly.

The working live ISO includes:

- `openssh-server`
- the installer at `/home/user/zfs-root-menu.sh`
- working PTYs via a mounted `devpts`
- baked-in live ZFS support so the live session does not need to build ZFS at runtime
- authorized key injection support for the live `user`

The live environment should be treated as a proper installer and rescue environment, not a place that rebuilds the live ZFS stack every run.

## Target Installer Path That Worked

The successful target-side path is:

1. Match exactly two disks by name and size.
2. Partition both disks with mirrored ESPs and mirrored ZFS members.
3. Create `zroot`, `zroot/ROOT`, and target datasets.
4. Bootstrap Debian Trixie into the target.
5. Install kernel, headers, DKMS, ZFS userspace, `dracut`, and `zfs-dracut` in the target.
6. Build and verify target `initrd.img-*` for ZFS readiness.
7. Install upstream prebuilt ZFSBootMenu EFI payload to both ESPs and fallback path.
8. Create mirrored UEFI entries and deduplicate old ZFSBootMenu entries.
9. Validate the install with `verify-install.sh` before rebooting.

## VM Network Model That Worked

The working VM network model ended up being:

- one NIC for host access on `host-bridge`
- one separate NIC for outbound internet on a real uplink-backed macvtap/macvlan path
- system libvirt mode, not session mode

Why this mattered:

- a dead or unmanaged `virbr0` looked valid at first but was not actually carrying traffic
- hidden or partially attached VM NICs created false conclusions about DHCP and routing
- macvlan/macvtap provided working outbound internet, but host access had to stay on a separate NIC because macvlan/macvtap does not give normal host-to-guest connectivity on the same parent path

## Hostid Handling

One of the more subtle problems was ZFS pool hostid mismatch.

The final approach was:

- preserve an existing target `/etc/hostid` if present
- otherwise generate one
- use that same hostid consistently in the target
- write `spl_hostid=` into the ZFSBootMenu command line

This avoids confusing pool-import behavior where ZFSBootMenu can only recover by rewriting hostid at boot.

## PTY and Chroot Mounting Lesson

A major early problem was PTYs breaking after the installer ran.

The fix was not just "mount devpts". The actual robust path was:

- ensure the live ISO mounts `devpts` during boot
- when bind-mounting `/dev`, `/proc`, and `/sys` into the target chroot, use recursive bind mounts and mark them `rslave`

Without the `rslave` step, recursive unmount during cleanup could propagate back into the live ISO and break `/dev/pts`, which then made `sudo`, APT logging, and other PTY users fail in confusing ways.

## Practical Warnings

These are the issues most likely to plague future users:

- Do not trust only the guest routing table when debugging VM networking. Verify the host-side bridge, tap attachment, and libvirt network state too.
- Keep the target on Debian's packaged `dracut`/`zfs-dracut` path and verify generated initramfs content before reboot.
- Do not allow boot-critical package or initramfs steps to fail quietly. It is better for the installer to stop than to produce a boot environment that only fails later.
- Do not assume graphical output is authoritative during early boot. Serial was consistently the most trustworthy view.
- Do not rely on a VM internet path that is not fully attached at the host bridge level.

## Operational Summary

The correct day-to-day flow is:

1. Build the remastered ISO.
2. Start a VM whose network model is known-good for both host access and outbound internet.
3. Boot the ISO and SSH into the live environment if desired.
4. Run the destructive installer.
5. Run `verify-install.sh` and require `RESULT: PASS`.
6. Reboot into ZFSBootMenu.
7. Verify serial console behavior (and menu countdown/selection flow).
8. Boot the installed Debian environment and confirm it mounts ZFS root without dropping to BusyBox initramfs.

If the disks already contain a valid target install and only the target boot stack needs regeneration, use `--repair-chroot` from the live ISO instead of reinstalling from scratch.
