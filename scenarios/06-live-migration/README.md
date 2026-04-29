# Scenario 06 -- Live Migration of Tenant VMs

Demonstrate that tenant worker VMs can be live-migrated between bare-metal
nodes **with zero downtime**, thanks to the OVN localnet networking backend.

## Why This Matters

Service providers must perform rolling infrastructure upgrades (OS patches,
OpenShift minor-version updates) without disrupting tenant workloads. Live
migration moves a running VM from one node to another while it keeps
processing requests. This is only possible when the networking layer is
managed by OVN rather than wired directly to a host bridge device.

## Talking Points

1. **Before (bridge CNI)**: VMs were bound to a host Linux bridge, making
   them non-migratable. Upgrades required VM shutdown and restart.
2. **After (OVN localnet)**: OVN manages L2 forwarding at the SDN level and
   re-programs flows atomically on the destination node during migration.
   VMs remain fully connected throughout.

## Steps

### 1. Check VM Migration Readiness

```bash
# On the hub cluster, check the NodePool live-migration condition
export KUBECONFIG=setup/.generated-hub-kubeconfig

oc get nodepool tenant-a -n clusters \
  -o jsonpath='{.status.conditions[?(@.type=="KubeVirtNodesLiveMigratable")]}{"\n"}'
```

> **With `ENABLE_EFS_LIVE_MIGRATION=true`:** The condition reports `True`
> because the VM root disks use the `efs-sc` StorageClass (RWX/Filesystem),
> and live migration is fully functional.
>
> **With `ENABLE_EFS_LIVE_MIGRATION=false` (default):** The condition shows
> `DisksNotLiveMigratable` because root PVCs use `gp3-csi` (EBS / RWO). The
> **networking** layer is migration-ready regardless, but live migration also
> requires RWX storage. On-premises deployments with shared storage (e.g.,
> OpenShift Data Foundation) will show `True` here.

### 2. Show Current VM Placement

```bash
# On the infra cluster, list VMIs and their host nodes
export KUBECONFIG=setup/.generated-virt-kubeconfig

oc get vmi -n clusters-tenant-a -o wide
# Note: each VMI shows the node it runs on in the NODENAME column
```

### 3. Trigger Live Migration

```bash
# Pick a VMI and migrate it
./scenarios/06-live-migration/trigger.sh
```

### 4. Watch the Migration

```bash
oc get vmim -n clusters-tenant-a -w
# Wait until Phase changes to "Succeeded"
```

### 5. Verify Continued Connectivity

```bash
# The tenant API server should remain reachable throughout
export KUBECONFIG=setup/.generated-tenant-a-kubeconfig
oc get nodes
oc get clusterversion
```

### 6. Confirm New Placement

```bash
export KUBECONFIG=setup/.generated-virt-kubeconfig
oc get vmi -n clusters-tenant-a -o wide
# The migrated VMI should now show a different NODENAME
```

## How It Works

```
Source Node                        Destination Node
┌──────────────────┐               ┌──────────────────┐
│  VMI (running)   │               │  VMI (migrating) │
│       │          │               │       │          │
│  OVN localnet    │──── OVN ────> │  OVN localnet    │
│  VLAN 300 tag    │  flow reprog  │  VLAN 300 tag    │
│       │          │               │       │          │
│  br-secondary    │               │  br-secondary    │
│  (OVS bridge)    │               │  (OVS bridge)    │
└──────────────────┘               └──────────────────┘
```

OVN tracks the VM's logical port. When KubeVirt initiates migration:

1. Memory pages are copied iteratively to the destination node
2. OVN pre-creates the logical port binding on the destination
3. At switchover, OVN atomically moves the port binding and updates
   all datapath flows across the cluster
4. The VM resumes on the destination with the same MAC/IP -- no ARP
   disruption, no packet loss (within the convergence window)
