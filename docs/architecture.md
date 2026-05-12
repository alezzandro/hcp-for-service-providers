# Demo Architecture

This document describes the two-cluster architecture used in the demo and how
it maps to a production service-provider deployment.

## Two-Cluster Topology

The demo deploys two OpenShift clusters on AWS:

### Hub Cluster (Management + Hosting)

- **Instance type**: 3× `m5.2xlarge` (8 vCPU, 32 GiB each)
- **Topology**: 3-node compact (masters are schedulable, no dedicated workers)
- **Components**:
  - Red Hat Advanced Cluster Management (ACM) — fleet management, governance,
    observability
  - Multicluster Engine (MCE) Operator — installed as an ACM dependency
  - HyperShift Operator — enabled via MCE, manages `HostedCluster` lifecycle
- **Role**: Hosts the control plane pods (kube-apiserver, etcd,
  konnectivity-server, oauth-server) for each tenant in dedicated namespaces
  (`clusters-tenant-a`, `clusters-tenant-b`)

### Infrastructure Cluster (Worker VMs)

- **Instance type**: 3× `m5.metal` (96 vCPU, 384 GiB each, bare-metal)
- **Topology**: 3-node compact (masters are schedulable, no dedicated workers)
- **Components**:
  - OpenShift Virtualization (KubeVirt) — runs tenant worker VMs
  - NMState Operator — configures secondary NIC, OVS bridge, OVN bridge-mapping
- **Role**: Hosts the KubeVirt VMs that serve as worker nodes for each tenant's
  hosted cluster. VMs are attached to OVN localnet networks with per-tenant VLAN
  tagging on a secondary network interface. VMs are fully live-migratable.

## External Infrastructure Topology

The demo uses HyperShift's **external infrastructure** feature to split the
control plane from the data plane across two clusters:

```
hcp create cluster kubevirt \
  --name tenant-a \
  --infra-kubeconfig-file <virt-cluster-kubeconfig> \
  --infra-namespace clusters-tenant-a \
  --additional-network name:clusters-tenant-a/nad-vlan300 \
  --kas-dns-name api.tenant-a.<base-domain> \
  ...
```

- Control plane pods run on the **hub cluster** (lightweight virtual instances)
- Worker VMs run on the **infra cluster** (bare-metal instances with OCP Virt)
- Konnectivity tunnels connect workers to their control plane over mTLS

This mirrors a production deployment where a service provider runs a
management/hosting cluster separate from the compute infrastructure.

## Network Isolation Layers

### Layer A — Control Plane Isolation (Hub Cluster)

Each tenant's control plane runs in a dedicated namespace. Isolation is
provided by:

1. **Namespace separation**: Each `HostedCluster` creates its own namespace
2. **HyperShift NetworkPolicies**: Auto-generated policies deny cross-namespace
   traffic between control planes
3. **AdminNetworkPolicy**: Platform-level deny rules that tenants cannot override
4. **Separate TLS/PKI**: Each cluster has unique certificates for Konnectivity,
   API server, and etcd encryption keys

### Layer B — Data Plane Isolation (Infra Cluster)

Worker VMs are isolated at L2 using OVN localnet networks with per-tenant VLAN
tagging on a secondary network interface:

1. **OVS bridge**: `br-secondary` on the secondary NIC, managed by NMState
2. **OVN bridge-mappings**: Per-tenant mappings (`tenant-a-physnet`, `tenant-b-physnet`)
   map to `br-secondary`, declared in the NMState NNCP `ovn.bridge-mappings` section
3. **OVN localnet NADs**: Each tenant's NAD specifies a unique localnet name and VLAN ID
   (300, 301); OVN
   tags frames at the OVS bridge port, creating separate L2 broadcast domains
4. **Live migration**: Because OVN manages L2 forwarding at the SDN level,
   KubeVirt can live-migrate VMs between nodes with zero downtime
5. **Unique CIDRs**: Each tenant gets non-overlapping pod and service CIDRs

### Layer C — Ingress/Egress Isolation

1. **MetalLB per tenant**: Dedicated ingress VIP per tenant, announced on the
   tenant's VLAN only
2. **EgressFirewall**: Restricts outbound traffic from each tenant
3. **IP masquerade**: OVN localnet traffic is NATted through the primary
   interface, simulating a VLAN gateway for outbound connectivity

## AWS-Specific Adaptations

The reference architecture was designed for physical data centers with VLAN
trunking. This demo adapts it for AWS:

| Production | AWS Demo |
|------------|----------|
| Bonded NIC with VLAN trunk | Secondary ENI with OVS bridge + OVN localnet |
| Physical switch VLAN routing | Node-local VLANs + IP masquerade for gateway |
| Cross-node VLAN L2 | VMs co-located on same node (AWS VLAN limitation) |
| External DHCP per VLAN | OVN built-in IPAM |
| Multiple MCE hosting clusters | Single hub cluster (demo scale) |

**Key AWS limitation**: VLAN-tagged frames do not traverse AWS VPC networking.
Tenant VMs for the same customer are co-located on the same bare-metal node
using pod affinity. In production, physical switches would trunk VLANs across
all nodes.

## Storage for Live Migration

KubeVirt live migration requires all VM PVCs to be `ReadWriteMany` (RWX) so
both the source and destination nodes can access the disk simultaneously during
migration. The demo provides a selectable toggle for this:

| Setting | StorageClass | Access Mode | Volume Mode | Live Migratable |
|---------|-------------|-------------|-------------|-----------------|
| `ENABLE_EFS_LIVE_MIGRATION=false` (default) | `gp3-csi` (EBS) | RWO | Block | No |
| `ENABLE_EFS_LIVE_MIGRATION=true` | `efs-sc` (EFS) | RWX | Filesystem | Yes |

When EFS is enabled, Terraform creates an EFS filesystem with mount targets in
each private subnet, and `06b-install-efs-csi.sh` installs the AWS EFS CSI
Driver Operator and creates the `efs-sc` StorageClass. Tenant provisioning
scripts then pass `--root-volume-storage-class efs-sc --root-volume-volume-mode
Filesystem --root-volume-access-modes ReadWriteMany` to `hcp create cluster
kubevirt`.

**Performance note:** EFS uses NFS and has higher random I/O latency than EBS.
VM boot times may be slightly longer. For production, use block-based RWX
storage such as Red Hat OpenShift Data Foundation (Ceph RBD), NetApp ONTAP, or
Pure Storage.

## Tenant Configuration

| Parameter | Tenant A | Tenant B |
|-----------|----------|----------|
| VLAN ID | 300 | 301 |
| OVN localnet | tenant-a-physnet (VLAN 300) | tenant-b-physnet (VLAN 301) |
| Cluster CIDR | 10.132.0.0/14 | 10.136.0.0/14 |
| Service CIDR | 172.31.0.0/16 | 172.32.0.0/16 |
| Machine Network | 10.100.30.0/24 | 10.100.31.0/24 |
| MetalLB VIP | 10.100.30.100 | 10.100.31.100 |
| Infra Namespace | clusters-tenant-a | clusters-tenant-b |
| Worker VMs | 2 | 2 |
