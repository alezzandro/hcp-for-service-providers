# Production Plan: Live-Migratable Tenant VMs with VLAN Isolation

## Current State

The demo now uses **OVN-Kubernetes localnet** topology for tenant VM secondary
networks (Option 1 below -- **implemented**). This solved the networking
blocker for live migration: KubeVirt no longer reports
`InterfaceNotLiveMigratable` and the secondary network interface is
migration-ready.

The storage blocker is now **solvable in the demo** via the
`ENABLE_EFS_LIVE_MIGRATION` toggle in `credentials.env`. When set to `"true"`:

1. Terraform creates an AWS EFS filesystem with mount targets and an NFS security group
2. `06b-install-efs-csi.sh` installs the AWS EFS CSI Driver Operator and creates
   an `efs-sc` StorageClass on the infra cluster
3. Tenant provisioning scripts pass `--root-volume-storage-class efs-sc`,
   `--root-volume-volume-mode Filesystem`, and `--root-volume-access-modes ReadWriteMany`

With EFS enabled, `KubeVirtNodesLiveMigratable` reports `True`.

When the toggle is `"false"` (default), VMs still use `gp3-csi` (EBS / RWO):

```
KubeVirtNodesLiveMigratable=False
Reason: DisksNotLiveMigratable
Message: PVC <vm>-rhcos is not shared, live migration requires that all
         PVCs must be shared (using ReadWriteMany access mode)
```

### Production RWX Storage Alternatives

EFS is suitable for demos but has higher random I/O latency than block storage.
Production deployments should use one of these certified RWX-capable providers:

| Provider | StorageClass Provisioner | Mode | Notes |
|----------|--------------------------|------|-------|
| Red Hat OpenShift Data Foundation | `openshift-storage.rbd.csi.ceph.com` | Block (RWX) | Recommended for OpenShift; built on Ceph |
| NetApp ONTAP (Trident) | `csi.trident.netapp.io` | Block or File (RWX) | Widely deployed in enterprise telco |
| Pure Storage (Portworx) | `pxd.portworx.com` | Block (RWX) | High-performance, cloud and on-prem |
| Dell/EMC PowerFlex | `csi-vxflexos.dellemc.com` | Block (RWX) | Scale-out SDS |
| AWS EFS (demo only) | `efs.csi.aws.com` | File (RWX) | NFS-based, higher latency |

## Historical Context

The original demo architecture used host Linux bridges (`br300`, `br301`) via
the `bridge` CNI plugin in a `NetworkAttachmentDefinition`. This bridge-binding
made every VMI **non-live-migratable** because KubeVirt cannot atomically move
a virtual NIC wired to a host bridge device to a destination host. That
networking blocker was resolved by migrating to OVN localnet.

## Why an Infra/Workload Node Split Alone Doesn't Solve It

A natural first idea is to split virt-cluster nodes into two roles:

| Role | Secondary NIC | Hosts |
|------|--------------|-------|
| **Infra nodes** | Yes (bridges, NMState, MetalLB) | Networking services only |
| **Workload nodes** | No | Tenant VMs (migratable) |

This **does not work** because the tenant VMs themselves are what's bound to the
bridge. The `bridge` CNI plugin connects the VM's virtual NIC directly to the
host bridge device. If the VM runs on a node without the bridge, it has no VLAN
connectivity. Moving the VM to a bridgeless node removes the isolation that the
architecture is designed to provide.

## Viable Solutions

### Option 1: OVN-Kubernetes Secondary Networks with LocalNet (recommended, available today)

**Available since:** OpenShift 4.14+

Instead of a `bridge` CNI plugin in the NAD, use OVN-Kubernetes **localnet**
topology. OVN handles L2 forwarding at the SDN level, not via direct host bridge
binding, so KubeVirt can live-migrate VMs.

**NetworkAttachmentDefinition (per tenant):**

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: tenant-a-vlan
  namespace: clusters-tenant-a
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "name": "tenant-a-vlan",
      "type": "ovn-k8s-cni-overlay",
      "topology": "localnet",
      "netAttachDefName": "clusters-tenant-a/tenant-a-vlan",
      "vlanID": 300
    }
```

**How it works:**

1. NMState NNCP still creates the bridge and maps the secondary NIC on every node.
2. An OVN `bridge-mapping` annotation on each node maps the OVN localnet name
   to the physical bridge (e.g., `tenant-vlan:br-secondary`).
3. OVN tags traffic with VLAN 300/301 at the bridge port, not inside the VM.
4. KubeVirt sees the VM's NIC as an OVN-managed port, **not** a direct host
   bridge port, so live migration is supported.
5. During migration, OVN re-programs flows on the destination node atomically.

**Trade-offs:**

| Pro | Con |
|-----|-----|
| Full VLAN isolation preserved | Requires OVN-Kubernetes as cluster CNI (default in OCP 4.12+) |
| VMs are fully live-migratable | Slightly more complex NAD configuration |
| Works on any NIC (no SR-IOV HW needed) | Small SDN overhead vs. direct bridge |
| Available today in supported OCP | Needs OVN bridge-mapping config per node |

### Option 2: SR-IOV with Migratable Virtual Functions

**Requires:** Intel E810, Mellanox ConnectX-5+ (switchdev mode)

SR-IOV creates hardware-isolated Virtual Functions (VFs) with VLAN tagging at
the NIC level. Some NIC families support live migration of SR-IOV VFs.

```yaml
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetwork
metadata:
  name: tenant-a-sriov
  namespace: openshift-sriov-network-operator
spec:
  resourceName: tenant_vf
  networkNamespace: clusters-tenant-a
  vlan: 300
  spoofChk: "on"
  trust: "off"
```

**Trade-offs:**

| Pro | Con |
|-----|-----|
| Near-line-rate performance | Hardware-dependent (NIC must support migratable VFs) |
| Hardware-level VLAN isolation | Not available on AWS ENA (`m5.metal`) |
| Lowest latency | Requires SR-IOV Operator + node policy |
| Live migration on supported HW | Limited VF count per physical function |

> **Note:** On AWS `m5.metal`, the Elastic Network Adapter (ENA) does not expose
> SR-IOV VFs in the traditional sense. This option is suited for on-premises
> bare-metal deployments with Intel or Mellanox NICs.

### Option 3: User Defined Networks (UDN) with HCP

**Expected:** Future OpenShift release (technology preview stage)

UDN provides per-namespace or per-pod network isolation managed by OVN, with
native live migration support. Once HCP integrates with UDN, each tenant's
`HostedCluster` namespace would get a dedicated network domain automatically.

**Trade-offs:**

| Pro | Con |
|-----|-----|
| Cleanest long-term architecture | Not yet GA for HCP workloads |
| Automatic per-namespace isolation | Requires OCP version with UDN GA |
| Built-in live migration | HCP integration timeline TBD |
| No manual NAD/NNCP management | |

## Recommended Production Topology (Option 1 + Node Roles)

Combining OVN localnet with an infra/worker node split gives the strongest
production posture:

```
Virt Cluster (bare-metal nodes, all have secondary NIC)
│
├── "infra" labeled nodes (2+, anti-affinity)
│   ├── Taints: node-role.kubernetes.io/infra:NoSchedule
│   ├── Run: NMState NNCP, OVN bridge-mappings, MetalLB speakers
│   ├── Run: Monitoring, logging, router pods
│   └── Upgrade: drain + restart (no tenant VM impact)
│
└── "worker" labeled nodes (3+, spread across AZs)
    ├── Run: Tenant VMs (via OVN localnet NADs)
    ├── VMs are FULLY LIVE-MIGRATABLE between worker nodes
    ├── Upgrade: drain → VMs live-migrate → patch → uncordon
    └── Business continuity: zero tenant downtime during rolling upgrade
```

### Upgrade Procedure

1. **Cordon** one worker node.
2. **Live-migrate** all tenant VMs off the cordoned node (automatic via
   `oc adm drain --delete-emptydir-data`; KubeVirt eviction triggers
   live migration).
3. **Patch/upgrade** the empty node.
4. **Uncordon** the node.
5. Repeat for next worker node.

Infra nodes are upgraded separately; they don't host tenant VMs, so draining
them only moves lightweight networking pods (MetalLB, NMState) which restart
in seconds.

### Capacity Planning

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| Infra nodes | 2 (HA) | 3 (across AZs) |
| Worker nodes | 3 | N+1 (one spare for migration headroom) |
| Secondary NICs | All nodes | All nodes (OVN localnet needs the physical mapping everywhere) |

The **N+1 worker** rule ensures there is always spare capacity to receive
migrating VMs during a rolling upgrade without overcommitting resources.

## Migration Path from Current Demo to Production

| Step | Change | Status |
|------|--------|--------|
| 1 | Replace `bridge` CNI NADs with OVN localnet NADs | **Done** |
| 2 | Add OVN bridge-mapping config to all nodes | **Done** |
| 3 | Replace RWO storage with RWX StorageClass | **Done** (EFS toggle) |
| 4 | Label nodes as `infra` / `worker` and apply taints | Pending |
| 5 | Add `nodeSelector` to tenant NodePool for worker nodes | Pending |
| 6 | Add anti-affinity rules for tenant VMs across workers | Pending |
| 7 | Validate live migration with `virtctl migrate <vmi>` | Pending |
| 8 | Test rolling upgrade: cordon → drain → upgrade → uncordon | Pending |

## References

- [OVN-Kubernetes Secondary Networks](https://docs.openshift.com/container-platform/4.16/networking/multiple_networks/configuring-additional-network.html)
- [KubeVirt Live Migration](https://docs.openshift.com/container-platform/4.16/virt/live_migration/virt-about-live-migration.html)
- [SR-IOV Network Operator](https://docs.openshift.com/container-platform/4.16/networking/hardware_networks/about-sriov.html)
- [NMState Operator](https://docs.openshift.com/container-platform/4.16/networking/k8s_nmstate/k8s-nmstate-about-the-k8s-nmstate-operator.html)
- [User Defined Networks (Tech Preview)](https://docs.openshift.com/container-platform/4.16/networking/user-defined-network/about-user-defined-network.html)
