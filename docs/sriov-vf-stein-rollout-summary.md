# SR-IOV VF Rollout Summary (Stein)

This document summarizes the SR-IOV VF passthrough rollout completed for `stein` on **March 29, 2026**.

## Goal

Implement deterministic NIC SR-IOV VF lifecycle management such that:

- PFs remain host-owned for normal host networking.
- Selected VFs are bound to `vfio-pci` for VM passthrough.
- Behavior is persistent and reproducible across reboot.

## What Was Implemented

1. Added a dedicated role: `roles/sriov_vf_manage`.
2. Wired role execution into `playbooks/zfsbootmenu-manage.yml` through `zfs_snapshot_guard`.
3. Added host-specific PF/VF config in `host_vars/stein.yml`.
4. Added/updated SR-IOV documentation in:
   - `docs/role-sriov_vf_manage.md`
   - `Readme.md`
   - `docs/ansible-zbm-role-runbook.md`

## Key Design Decisions

- Use **per-VF binding** (`driver_override` + `drivers_probe`) instead of global NIC `vfio-pci.ids=...`.
- Keep PF devices on host NIC drivers.
- Allow `numvfs: 0` as a placeholder so inactive PF plans can stay in host vars.
- Add retry logic around sysfs unbind/probe operations to handle transient races.

## Stein Configuration Applied

From `host_vars/stein.yml`:

- `eno1`: `numvfs=4`, `bind_all_vfs=true`
- `eno2`: `numvfs=4`, `bind_all_vfs=true`
- `eno3`: `numvfs=0`, placeholder
- `eno4`: `numvfs=0`, placeholder
- `enp137s0f0`: `numvfs=4`, `bind_all_vfs=true`
- `enp137s0f1`: `numvfs=0`, placeholder

## Validation Performed

1. `ansible-playbook --check --diff` completed successfully.
2. Full apply run completed successfully.
3. Host reboot completed successfully.
4. Post-reboot verification confirmed:
   - `sriov-vf-manage.service` active and successful.
   - Host networking remained up (`eno1`, `eno2`, `enp137s0f0`, `enp137s0f1`).
   - SR-IOV PF state persisted:
     - `eno1 current=4`
     - `eno2 current=4`
     - `eno3 current=0`
     - `eno4 current=0`
     - `enp137s0f0 current=4`
     - `enp137s0f1 current=0`
   - All active VF BDFs bound to `vfio-pci`.

## Current Operational State

- SR-IOV lifecycle is now managed by Ansible + systemd.
- NIC PF host networking is preserved.
- VM passthrough VFs are ready to attach in libvirt.

