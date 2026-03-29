# sriov_vf_manage

Manages SR-IOV virtual-function lifecycle on Debian hosts and binds only selected VFs to `vfio-pci` for VM passthrough.

## Safety Model

- Never binds PFs to `vfio-pci`
- Keeps every PF bound to its host NIC driver
- Creates/reconciles VFs via `sriov_numvfs`
- Binds only configured VF indexes to `vfio-pci`
- Accepts `numvfs: 0` placeholders in explicit PF configs
- Clears `driver_override` on non-selected VFs so host drivers can claim them
- Retries sysfs unbind/probe writes to handle transient VF driver races

## Example (all SR-IOV-capable NIC PFs)

```yaml
sriov_vf_manage_enable: true
sriov_vf_manage_manage_all_capable_pfs: true
sriov_vf_manage_default_numvfs: 1
sriov_vf_manage_default_bind_all_vfs: true
```

## Example (explicit PF interface list)

```yaml
sriov_vf_manage_enable: true
sriov_vf_manage_manage_all_capable_pfs: false
sriov_vf_manage_pf_configs:
  - interface: enp137s0f0
    numvfs: 4
    bind_all_vfs: true
  - interface: enp137s0f1
    numvfs: 4
    passthrough_vf_indexes: [0, 1]
```

## Outputs

- Script: `{{ sriov_vf_manage_script_path }}`
- Service: `/etc/systemd/system/{{ sriov_vf_manage_service_name }}`

The service is enabled and started by default and can run before `libvirtd.service`.
