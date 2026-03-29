# zfs_snapshot_guard

Wraps another role execution in recursive ZFS snapshots on a target pool.

## Behavior

- creates `before-<role>-<timestamp>` snapshot before wrapped role execution
- runs wrapped role
- if wrapped role changed state:
  - creates `after-<role>-<timestamp>` snapshot
  - keeps `before-*` snapshot
- if wrapped role changed nothing:
  - removes `before-*` snapshot (default behavior)
  - does not create `after-*` snapshot
- if wrapped role fails:
  - attempts live rollback to `before-*`
  - destroys `before-*` after successful rollback (default behavior)
  - if live rollback fails and enabled, creates fallback boot environment clone and points `bootfs` to it

## Required variable

- `zfs_guard_target_role`: role name to execute

## Example

```yaml
- name: Run guarded role
  include_role:
    name: zfs_snapshot_guard
  vars:
    zfs_guard_target_role: zfsbootmenu_manage
```

## Notes

- live rollback of mounted root datasets can fail; fallback BE mode is provided for that case
- if fallback BE is created, `before-*` snapshot is retained as clone origin
