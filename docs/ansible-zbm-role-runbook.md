# ZBM Role Runbook (Stein)

This runbook covers safe use of `roles/zfsbootmenu_manage` on `stein`.

## Files

- `ansible.cfg`
- `inventory.yml`
- `playbooks/zfsbootmenu-manage.yml`
- `host_vars/stein.yml`

## 1) Check pass (required first)

```bash
ansible-playbook playbooks/zfsbootmenu-manage.yml --limit stein --check --diff
```

The playbook runs `zfsbootmenu_manage` through `zfs_snapshot_guard`.
Guard naming pattern:

- `before-zfsbootmenu_manage-<timestamp>`
- `after-zfsbootmenu_manage-<timestamp>`

## 2) Apply run

```bash
ansible-playbook playbooks/zfsbootmenu-manage.yml --limit stein
```

Current `host_vars/stein.yml` behavior:

- rebuilds initramfs for the running kernel using dracut
- verifies ZFS content in rebuilt initramfs
- manages `/etc/zfsbootmenu/config.yaml`
- keeps stein baseline `org.zfsbootmenu:commandline` values
- persists VFIO binding setup (`/etc/modprobe.d/vfio.conf`, dracut vfio preload)
- manages mirrored ESP sync (`sync-efi.sh`, `efi-sync.service`, `efi-sync.path`)
- does not run `generate-zbm` automatically
- snapshots are pruned automatically when the run reports no changes

## 3) Extend boot parameters

Append only new parameters in `host_vars/stein.yml`:

```yaml
zbm_manage_kernel_commandline_extra_tokens:
  - intel_iommu=on
  - iommu=pt
  - vfio-pci.ids=10de:1b06,10de:10ef

zbm_manage_vfio_enable: true
zbm_manage_vfio_ids:
  - "1002:7551"
  - "1002:ab40"
```

Then run check/apply again.

## 4) Compare against pre-change snapshot

Find latest baseline:

```bash
ssh root@stein "zfs list -H -t snapshot -o name -s creation | sed -n 's#^zroot@\\(pre-vfio-passthru-.*\\)#\\1#p' | tail -n1"
```

Per-dataset diff counts:

```bash
ssh root@stein 'for ds in $(zfs list -H -o name -r zroot); do snap=${ds}@pre-vfio-passthru-20260329-0820; if zfs list -H -t snapshot "$snap" >/dev/null 2>&1; then cnt=$(zfs diff -FH "$snap" 2>/dev/null | wc -l | tr -d " "); printf "%s\t%s\n" "$ds" "$cnt"; fi; done'
```

Focused root dataset diff:

```bash
ssh root@stein 'zfs diff -FH zroot/ROOT/trixie@pre-vfio-passthru-20260329-0820 | sed -n "1,200p"'
```

## 5) Rollback (if needed)

Rollback the root dataset to baseline snapshot tag:

```bash
ssh root@stein 'zfs rollback -r zroot/ROOT/trixie@pre-vfio-passthru-20260329-0820'
```

If you need full pool-wide rollback, perform rollback per affected dataset from the same snapshot tag.
Do this only during controlled downtime.
