# zfsbootmenu_manage

Installs and manages local ZFSBootMenu build tooling on Debian hosts so `generate-zbm` is available with safe defaults for existing systems.

## Behavior

- Installs dependencies: `git`, `make`, `dracut`, `zfs-dracut`
- Clones `zbm-dev/zfsbootmenu` into `/opt/zfsbootmenu-src`
- Runs `make` only when needed (new checkout/update/missing binary/forced rebuild)
- Installs `generate-zbm` to `/usr/local/sbin/generate-zbm`
- Optionally rebuilds host initramfs with dracut and verifies ZFS content
- Optionally writes persistent VFIO config (`/etc/modprobe.d/vfio.conf` + dracut driver preload)
- Creates `/etc/zfsbootmenu/config.yaml`
- Applies `org.zfsbootmenu:commandline` to `zroot/ROOT` and `bootfs` dataset (configurable)
- Uses stein-derived default kernel args (including ARC tuning + console + `spl_hostid`)
- Installs mirrored-ESP sync flow (`/usr/local/sbin/sync-efi.sh`, `efi-sync.service`, `efi-sync.path`)
- Does **not** run `generate-zbm` unless explicitly enabled
- Does **not** modify EFI entries or bootloader configuration

## Example

```yaml
- hosts: stein
  become: true
  roles:
    - role: zfsbootmenu_manage
      vars:
        zbm_manage_rebuild_initramfs: true
        zbm_manage_run_generate: false
        zbm_manage_run_generate_on_change: false
```

## Extending kernel parameters

Use `zbm_manage_kernel_commandline_extra_tokens` to append boot parameters while keeping the base set:

```yaml
zbm_manage_kernel_commandline_extra_tokens:
  - intel_iommu=on
  - iommu=pt
  - vfio-pci.ids=10de:1b06,10de:10ef
```

For persistent boot-time binding with dracut:

```yaml
zbm_manage_vfio_enable: true
zbm_manage_vfio_ids:
  - "1002:7551"
  - "1002:ab40"
```

## Common toggles

- `zbm_manage_rebuild_initramfs`: rebuild initramfs with dracut (`false` by default)
- `zbm_manage_run_generate`: run `generate-zbm` during the play (explicit trigger)
- `zbm_manage_run_generate_on_change`: run `generate-zbm` only via handlers when binary/config changes
- `zbm_manage_post_generate_hooks`: list of commands for mirrored-ESP sync or similar
- `zbm_manage_config_content`: raw YAML string override for `config.yaml`
- `zbm_manage_config`: structured config when not using raw content override
- `zbm_manage_required_mountpoints`: defaults to `[/boot/efi]` (safe for hosts where `/boot` is not a separate mount)
- `zbm_manage_kernel_commandline_tokens`: base kernel parameters
- `zbm_manage_kernel_commandline_extra_tokens`: append extra parameters (VF/NIC/GPU use cases)
- `zbm_manage_enable_efi_mirror_sync`: enable/disable ESP mirror sync management
- `zbm_manage_mirror_efi_mountpoint` / `zbm_manage_mirror_efi_device`: mirror ESP target
