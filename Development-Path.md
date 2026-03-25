# Development Path

This file records the working path that emerged during development of this repo. It intentionally leaves out the dead ends except where they are useful as warnings.

## Final Working Shape

The working result was:

- a remastered Debian Trixie live ISO
- a live environment with SSH and baked-in ZFS support
- a destructive installer that creates a mirrored ZFS root on two disks
- a target system that boots through ZFSBootMenu
- ZFSBootMenu pre-boot SSH access via Dropbear
- an installed Debian system that boots its ZFS root using a verified ZFS-capable initramfs

## Working Boot Stack

The final boot path is split into two layers:

1. ZFSBootMenu layer
- built inside the target chroot
- uses source-built `dracut`
- uses Debian packaged `dracut`/`dracut-network`/`zfs-dracut` and no pre-boot Dropbear SSH
- includes explicit driver loading for storage and network so early networking is predictable
- uses a consistent `spl_hostid=` kernel argument so pool import behavior is stable

2. Installed system layer
- uses Debian's normal `initramfs-tools`
- installs `zfs-initramfs`
- regenerates `initrd.img-*`
- verifies the resulting initramfs actually contains ZFS-related content before the installer continues

That distinction matters. ZFSBootMenu can work perfectly and still hand off to a broken installed-system initramfs if the target initramfs is not truly ZFS-capable.

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

The successful target-side path was:

1. Match exactly two disks by name and size.
2. Partition both disks with mirrored ESPs and mirrored ZFS members.
3. Create `zroot` and the child datasets.
4. Debootstrap Debian Trixie into the target.
5. Install kernel, headers, DKMS, ZFS userspace, `initramfs-tools`, `zfs-initramfs`, and packaged `dracut`/`zfs-dracut` in the target.
6. Build source `dracut` in the target.
7. Use Debian's packaged dracut stack in the target; no custom dracut or Dropbear build step.
8. Build ZFSBootMenu in the target.
9. Generate a verified Debian initramfs for the installed kernel.
10. Write UEFI entries for both ESPs plus the `BOOTX64.EFI` fallback path.

## VM Network Model That Worked

The working VM network model ended up being:

- one NIC for host access on `host-bridge`
- one separate NIC for outbound internet on a real uplink-backed macvtap/macvlan path
- system libvirt mode, not session mode

Why this mattered:

- a dead or unmanaged `virbr0` looked valid at first but was not actually carrying traffic
- hidden or partially attached VM NICs created false conclusions about DHCP and routing
- macvlan/macvtap provided working outbound internet, but host access had to stay on a separate NIC because macvlan/macvtap does not give normal host-to-guest connectivity on the same parent path

## ZFSBootMenu Network Bring-Up

The successful ZFSBootMenu path required all of the following:

- detect the active NIC drivers from the live environment
- carry those drivers into the target configuration
- include them with `add_drivers+=...`
- request early load with `force_drivers+=...`
- add `rd.driver.pre=...` entries so dracut requests them very early
- steer dracut toward the intended boot network rather than leaving it to pick the wrong NIC in a multi-interface VM

Without explicit early driver handling, the VM could see the PCI NIC device while still failing to create any usable `ethX`/`enpXsY` device during the ZFSBootMenu boot.

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
- Do not mix a distro-managed dracut stack and a source-installed dracut stack casually. The final working path used source dracut only for ZFSBootMenu and Debian's normal initramfs path for the installed system.
- Do not allow boot-critical package or initramfs steps to fail quietly. It is better for the installer to stop than to produce a boot environment that only fails later.
- Do not assume graphical output is authoritative during early boot. Serial was consistently the most trustworthy view.
- Do not assume Dropbear login user names match the live ISO login. ZFSBootMenu Dropbear login is `root`.
- Do not rely on a VM internet path that is not fully attached at the host bridge level.

## Operational Summary

The correct day-to-day flow is:

1. Build the remastered ISO.
2. Start a VM whose network model is known-good for both host access and outbound internet.
3. Boot the ISO and SSH into the live environment if desired.
4. Run the destructive installer.
5. Reboot into ZFSBootMenu.
6. Verify pre-boot SSH and serial console behavior.
7. Boot the installed Debian environment and confirm it mounts ZFS root without dropping to BusyBox initramfs.

If the disks already contain a valid target install and only the target boot stack needs regeneration, use `--repair-chroot` from the live ISO instead of reinstalling from scratch.
