# Role: `sriov_vf_manage`

`sriov_vf_manage` manages NIC SR-IOV VF lifecycle on Debian hosts for VM passthrough.

It is designed so that **PFs remain host-owned** and only selected/generated VFs are bound to `vfio-pci`.

## Purpose

- Keep each physical NIC PF on host networking drivers.
- Reconcile VF counts per PF via `sriov_numvfs`.
- Bind selected VFs to `vfio-pci` for guest passthrough.
- Persist state across reboot with `sriov-vf-manage.service`.

## Safety Model

- Never binds PF devices to `vfio-pci`.
- Uses per-device binding (VF BDF level), not global `vfio-pci.ids` for NIC PF IDs.
- Accepts `numvfs: 0` as a valid placeholder in host vars.
- Uses retry logic for sysfs unbind/probe operations to tolerate transient driver races.

## What It Manages

- Script: `/usr/local/sbin/sriov-vf-manage.sh`
- Service: `/etc/systemd/system/sriov-vf-manage.service`

## Execution Flow

1. Discover SR-IOV-capable PF interfaces from `/sys/class/net/*/device/sriov_totalvfs`.
2. Build effective PF config from either:
   - `sriov_vf_manage_manage_all_capable_pfs: true`, or
   - explicit `sriov_vf_manage_pf_configs`.
3. Normalize passthrough VF indexes:
   - `bind_all_vfs: true` -> `[0..numvfs-1]`
   - otherwise use `passthrough_vf_indexes`.
4. Validate requested `numvfs` and VF index ranges.
5. Render script and systemd service.
6. Enable/start service (outside check mode).
7. Optionally run script immediately (`sriov_vf_manage_apply_now`).

## Variables

Core toggles:

- `sriov_vf_manage_enable`
- `sriov_vf_manage_manage_all_capable_pfs`
- `sriov_vf_manage_apply_now`
- `sriov_vf_manage_enable_service`

PF configuration:

- `sriov_vf_manage_pf_configs`
- `sriov_vf_manage_default_numvfs`
- `sriov_vf_manage_default_passthrough_vf_indexes`
- `sriov_vf_manage_default_bind_all_vfs`
- `sriov_vf_manage_pf_overrides`

Service/script paths:

- `sriov_vf_manage_script_path`
- `sriov_vf_manage_service_name`
- `sriov_vf_manage_before_services`

## Example: Explicit PF List

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

`numvfs: 0` entries are treated as placeholders and are intentionally allowed.

## Verification Commands

Show PF SR-IOV state:

```bash
for n in /sys/class/net/*; do
  iface=${n##*/}
  [ -r "$n/device/sriov_totalvfs" ] || continue
  total=$(cat "$n/device/sriov_totalvfs")
  [ "$total" -gt 0 ] || continue
  cur=$(cat "$n/device/sriov_numvfs")
  echo "$iface total=$total current=$cur"
done | sort
```

Show VF binding drivers:

```bash
for pf in eno1 eno2 eno3 eno4 enp137s0f0 enp137s0f1; do
  dev="/sys/class/net/$pf/device"
  [ -d "$dev" ] || continue
  printf "%s: " "$pf"
  for vf in "$dev"/virtfn*; do
    [ -e "$vf" ] || continue
    bdf=$(basename "$(readlink -f "$vf")")
    drv=$(basename "$(readlink -f "/sys/bus/pci/devices/$bdf/driver" 2>/dev/null)" 2>/dev/null || echo none)
    printf "%s=%s " "$bdf" "$drv"
  done
  echo
done
```

## Notes

- This role is separate from GPU VFIO config in `zfsbootmenu_manage`.
- Keep NIC PFs out of global `vfio-pci.ids=` binding.
