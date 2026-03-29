# Role: `zfs_snapshot_guard`

`zfs_snapshot_guard` wraps another role execution in a recursive ZFS snapshot envelope.

## Purpose

- Create a transactional guardrail around role runs on ZFS-root hosts.
- Keep paired `before-...` / `after-...` snapshots when changes occur.
- Auto-prune unnecessary snapshots on no-change runs.
- Attempt failure rollback, with fallback boot-environment clone support.

## Snapshot Naming

For target role `zfsbootmenu_manage` and timestamp `20260329-133039`:

- `before-zfsbootmenu_manage-20260329-133039`
- `after-zfsbootmenu_manage-20260329-133039`

The wrapper generates the timestamp once and reuses it for both names.

## Execution Flow

1. Validate `zfs_guard_target_role`.
2. Build timestamp and snapshot names.
3. Create recursive `before-*` snapshot on `zfs_guard_pool`.
4. Run wrapped role via `include_role`.
5. Detect actual filesystem mutations via `zfs diff` against `before-*`.
6. Success path:
   - changed: create recursive `after-*` snapshot (keep `before-*`)
   - unchanged: prune `before-*` (default)
7. Failure path (`rescue`):
   - try live rollback to `before-*`
   - optionally destroy `before-*` after successful rollback
   - if rollback fails and fallback enabled:
     - clone fallback BE from `bootfs@before-*`
     - set `zpool bootfs` to fallback BE
     - optionally reboot

## Key Variables

- `zfs_guard_enabled` (`true`)
- `zfs_guard_pool` (`zroot`)
- `zfs_guard_target_role` (required)
- `zfs_guard_before_prefix` (`before`)
- `zfs_guard_after_prefix` (`after`)
- `zfs_guard_timestamp_format` (`+%Y%m%d-%H%M%S`)
- `zfs_guard_prune_before_on_nochange` (`true`)
- `zfs_guard_create_after_on_success` (`true`)
- `zfs_guard_live_rollback_on_failure` (`true`)
- `zfs_guard_destroy_before_on_failure` (`true`)
- `zfs_guard_fallback_be_on_rollback_fail` (`true`)
- `zfs_guard_fallback_be_prefix` (`rollback`)
- `zfs_guard_auto_reboot_to_fallback_be` (`false`)

## Example Usage

```yaml
- name: Run role through snapshot guard
  hosts: stein
  become: true
  tasks:
    - name: Guarded zfsbootmenu role
      ansible.builtin.include_role:
        name: zfs_snapshot_guard
      vars:
        zfs_guard_target_role: zfsbootmenu_manage
```

## Notes

- Change detection is based on `zfs diff`, not `include_role` changed flags.
- Live rollback of mounted root datasets may fail; fallback BE path exists for this reason.
