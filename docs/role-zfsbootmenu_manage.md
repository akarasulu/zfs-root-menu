# Role: `zfsbootmenu_manage`

`zfsbootmenu_manage` manages local ZFSBootMenu build tooling and boot pipeline state on Debian ZFS-root systems.

## Purpose

- Install/refresh `generate-zbm` build tooling from upstream source.
- Rebuild host initramfs with dracut (optional).
- Maintain `org.zfsbootmenu:commandline` dataset properties.
- Maintain mirrored ESP sync workflow (`/boot/efi` -> `/boot/efi2`).
- Optionally persist VFIO binding config and dracut preload.

## What It Manages

- Source checkout: `/opt/zfsbootmenu-src`
- Binary install: `/usr/local/sbin/generate-zbm`
- Config: `/etc/zfsbootmenu/config.yaml`
- Optional VFIO config:
  - `/etc/modprobe.d/vfio.conf`
  - `/etc/dracut.conf.d/10-vfio.conf`
- EFI mirror sync:
  - `/usr/local/sbin/sync-efi.sh`
  - `/etc/systemd/system/efi-sync.service`
  - `/etc/systemd/system/efi-sync.path`

## Execution Flow

1. Validate Debian-family host.
2. Install package prerequisites.
3. Clone/update ZBM source and build when needed.
4. Install `generate-zbm`.
5. Optionally deploy VFIO modprobe/dracut configs.
6. Optionally rebuild initramfs with dracut and verify ZFS presence.
7. Deploy `/etc/zfsbootmenu/config.yaml`.
8. Validate required mount points.
9. Read hostid/bootfs and manage `org.zfsbootmenu:commandline` on datasets.
10. Configure mirror-ESP sync script + systemd path/service.
11. Optionally run `generate-zbm` and/or immediate mirror sync.

## Key Variables

### Build/Install

- `zbm_manage_packages`
- `zbm_manage_repo_url`
- `zbm_manage_repo_version`
- `zbm_manage_repo_dest`
- `zbm_manage_repo_force`
- `zbm_manage_force_rebuild`
- `zbm_manage_generate_zbm_path`

### Initramfs

- `zbm_manage_rebuild_initramfs`
- `zbm_manage_initramfs_kernel`
- `zbm_manage_initramfs_path`
- `zbm_manage_verify_initramfs_contains_zfs`

### ZBM Config

- `zbm_manage_config_path`
- `zbm_manage_config` / `zbm_manage_config_content`

### Kernel Commandline Dataset Properties

- `zbm_manage_set_kernel_commandline`
- `zbm_manage_zpool_name`
- `zbm_manage_root_dataset`
- `zbm_manage_apply_commandline_to_bootfs`
- `zbm_manage_kernel_commandline_tokens`
- `zbm_manage_kernel_commandline_extra_tokens`

### VFIO Persistence

- `zbm_manage_vfio_enable`
- `zbm_manage_vfio_ids`
- `zbm_manage_vfio_softdep_modules`
- `zbm_manage_vfio_modprobe_config_path`
- `zbm_manage_vfio_dracut_config_path`
- `zbm_manage_vfio_drivers`

### Mirrored ESP Sync

- `zbm_manage_enable_efi_mirror_sync`
- `zbm_manage_primary_efi_mountpoint`
- `zbm_manage_mirror_efi_mountpoint`
- `zbm_manage_mirror_efi_device`
- `zbm_manage_mirror_sync_script_path`
- `zbm_manage_mirror_sync_path_name`
- `zbm_manage_run_mirror_sync_now`

### `generate-zbm` Execution Controls

- `zbm_manage_run_generate`
- `zbm_manage_run_generate_on_change`
- `zbm_manage_generate_extra_args`
- `zbm_manage_post_generate_hooks`

## Example: Stein VFIO + ZBM

```yaml
zbm_manage_rebuild_initramfs: true
zbm_manage_vfio_enable: true
zbm_manage_vfio_ids:
  - "1002:7551"
  - "1002:ab40"
zbm_manage_kernel_commandline_extra_tokens:
  - intel_iommu=on
  - iommu=pt
  - vfio-pci.ids=1002:7551,1002:ab40
```

## Notes

- Role intentionally does not modify EFI boot NVRAM entries.
- `generate-zbm` remains explicit unless enabled by variables.
