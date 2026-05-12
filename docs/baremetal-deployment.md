# Bare-Metal Deployment Guide

This document maps every AWS-specific component in the demo to its bare-metal
equivalent. A service provider architect can use it as a checklist to implement
the same multi-tenant HCP architecture on on-premises infrastructure.

The demo runs on AWS only because the lab environment was cloud-based. The
target architecture is always **bare-metal**: hub cluster on standard servers,
infrastructure cluster on OCP-Virt-certified bare-metal nodes with VLAN
trunking to a physical switch fabric.

> **Reading order**: Start with [architecture.md](architecture.md) for the
> overall two-cluster topology and network isolation layers. This document
> focuses on what changes when moving from AWS to bare-metal.

---

## 1. Cluster Installation

### AWS Demo

Both clusters are installed with IPI on AWS:

- Hub: 3x `m5.2xlarge` (8 vCPU, 32 GiB) -- compact, masters schedulable
- Infra: 3x `m5.metal` (96 vCPU, 384 GiB) -- bare-metal instances for OCP Virt

See [install-configs/hub-install-config.yaml.tpl](../install-configs/hub-install-config.yaml.tpl)
and [install-configs/virt-install-config.yaml.tpl](../install-configs/virt-install-config.yaml.tpl).

### Bare-Metal Equivalent

| | Hub Cluster | Infrastructure Cluster |
|---|---|---|
| **Minimum nodes** | 3 (compact) | 3 (compact) or 3 infra + 3+ workers |
| **CPU** | 8+ vCPU per node | 64+ cores per node (hosts many tenant VMs) |
| **RAM** | 32+ GiB per node | 384+ GiB per node (VMs need dedicated memory) |
| **Storage** | 250 GiB SSD per node | 500+ GiB NVMe per node + shared RWX storage |
| **NICs** | 1x 10 GbE (management) | 2x 10/25 GbE (management + VLAN trunk) |
| **BMC** | IPMI / Redfish | IPMI / Redfish |
| **BIOS** | VT-x enabled | VT-x, VT-d, IOMMU enabled; SR-IOV if used |

#### Installation Methods (choose one)

1. **Assisted Installer (recommended)** -- web-based or API-driven; manages
   discovery ISO, introspection, DHCP, and BMC boot. Best for connected
   environments with a Red Hat Hybrid Cloud Console subscription.

2. **Agent-based Installer** -- generates a self-contained boot ISO with
   embedded `install-config.yaml` and `agent-config.yaml`. No external service
   required. Best for disconnected or air-gapped data centers.

3. **IPI with `platform: baremetal`** -- uses `openshift-install` with
   Redfish/IPMI for automated node provisioning. Requires a provisioning
   network (PXE) and a bootstrap VM.

All three methods produce the same OCP cluster. The choice depends on
connectivity, automation maturity, and whether BMC access is available.

#### Sample `install-config.yaml` Skeleton (Infra Cluster, Agent-Based)

```yaml
apiVersion: v1
metadata:
  name: virt
baseDomain: example.com
networking:
  networkType: OVNKubernetes
  clusterNetwork:
    - cidr: 10.128.0.0/14
      hostPrefix: 23
  serviceNetwork:
    - 172.30.0.0/16
  machineNetwork:
    - cidr: 192.168.10.0/24       # management network CIDR
controlPlane:
  name: master
  replicas: 3
compute:
  - name: worker
    replicas: 0                    # compact: masters are schedulable
platform:
  baremetal:
    apiVIPs:
      - 192.168.10.10
    ingressVIPs:
      - 192.168.10.11
    hosts:
      - name: node-0
        role: master
        bmc:
          address: redfish-virtualmedia://192.168.10.100/redfish/v1/Systems/1
          username: admin
          password: <bmc-password>
        bootMACAddress: aa:bb:cc:dd:ee:01
        rootDeviceHints:
          deviceName: /dev/nvme0n1
      # ... repeat for node-1, node-2
pullSecret: '...'
sshKey: '...'
```

---

## 2. Networking -- Secondary NIC and VLAN Trunking

This is the largest difference between the AWS demo and bare-metal.

### AWS Demo

```
┌──────────────────────────────────────────────┐
│              AWS VPC  10.0.0.0/16            │
│                                              │
│  Primary ENI (ens5)    Secondary ENI (ens6)  │
│  ├── OCP SDN           └── br-secondary      │
│  ├── GENEVE tunnels        ├── VLAN 300      │
│  └── Management            └── VLAN 301      │
│                                              │
│  VLANs are NODE-LOCAL                        │
│  (AWS does not forward tagged frames)        │
│                                              │
│  IP masquerade simulates VLAN gateway        │
│  VMs must be co-located on the same node     │
└──────────────────────────────────────────────┘
```

AWS-specific components that **disappear** on bare-metal:

| AWS Component | Script / Config | Why It Disappears |
|---|---|---|
| Terraform VPC, subnets, NAT | `terraform/*.tf` | Physical network replaces VPC |
| Secondary ENI creation | `setup/04-attach-secondary-nic.sh` | NIC is physically present |
| Source/dest check disable | `setup/04-attach-secondary-nic.sh` | No such concept on physical NICs |
| IP masquerade rules | `setup/07-configure-secondary-network.sh` (lines 78-101) | Physical VLAN gateway on the switch |
| ELB for tenant API | AWS auto-creates per `LoadBalancer` svc | MetalLB on hub cluster instead |
| Route53 DNS records | `terraform/dns.tf`, setup scripts | External DNS (BIND, Infoblox, etc.) |
| EFS for RWX storage | `terraform/efs.tf`, `setup/06b-install-efs-csi.sh` | ODF or enterprise SAN |

### Bare-Metal Network Topology

```
┌─────────────────────────────────────────────────────────────┐
│                     Physical Switch Fabric                  │
│                                                             │
│   Trunk port (VLANs 300,301,...)    Management VLAN         │
│         │                                  │                │
│         ▼                                  ▼                │
│  ┌──────────────────────────────────────────────────┐       │
│  │              Bare-Metal Node                     │       │
│  │                                                  │       │
│  │  ens1f0 (management)    ens2f0 (tenant trunk)    │       │
│  │  ├── OCP SDN            └── br-secondary (OVS)   │       │
│  │  ├── GENEVE tunnels         ├── VLAN 300 (A)     │       │
│  │  └── API / Mgmt             ├── VLAN 301 (B)     │       │
│  │                              └── VLAN 302 (C)    │       │
│  └──────────────────────────────────────────────────┘       │
│                                                             │
│  VLANs traverse the switch fabric                           │
│  Full cross-node L2 per tenant                              │
│  Physical router provides VLAN gateway                      │
│  VMs can live-migrate to ANY node                           │
└─────────────────────────────────────────────────────────────┘
```

Key advantages on bare-metal:

- **Cross-node L2**: VMs on the same VLAN communicate across nodes via the
  physical switch. The AWS demo's co-location constraint disappears.
- **Real VLAN gateway**: A physical router or L3 switch provides the default
  gateway for each VLAN -- no `iptables` masquerade.
- **Live migration anywhere**: Since every node has the trunk NIC, VMs can
  migrate to any node in the cluster (not just same-node).

### What Stays the Same

The OVN localnet configuration is **identical** on bare-metal:

- **NNCP** ([manifests/virt/nncp-ovs-bridge.yaml](../manifests/virt/nncp-ovs-bridge.yaml)) --
  reusable as-is. Only the `__SECONDARY_NIC__` placeholder changes (e.g.,
  `ens2f0` or `bond1` instead of `ens1`). Script `07-configure-secondary-network.sh`
  auto-detects the NIC name.
- **OVN bridge-mappings** -- declared in the NNCP, no changes needed.
- **NADs** (`nad-vlan300.yaml`, `nad-vlan301.yaml`) -- identical; OVN localnet
  topology with VLAN tagging works the same way.
- **AdminNetworkPolicy** -- hub and infra ANPs are cluster-level resources,
  completely infrastructure-agnostic.

### Physical Switch Configuration Checklist

| Item | Setting |
|------|---------|
| Port mode | **Trunk** (802.1Q) on the tenant-facing NIC |
| Allowed VLANs | 300, 301, and any future tenant VLANs |
| Native VLAN | Untagged management VLAN or none (depends on site) |
| STP | Disable on server-facing ports (or use RSTP with portfast) |
| MTU | 9000 (jumbo frames) recommended for overlay + VLAN |
| LACP | If using NIC bonding: bond the trunk ports with LACP (802.3ad) |

### NIC Bonding (Recommended for Production)

In production, the tenant trunk should be bonded for redundancy:

```yaml
# NNCP with bonded trunk NIC
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: secondary-nic-ovs-bridge
spec:
  nodeSelector:
    node-role.kubernetes.io/master: ""
  desiredState:
    interfaces:
      - name: bond-tenant
        type: bond
        state: up
        link-aggregation:
          mode: 802.3ad
          options:
            miimon: "100"
          port:
            - ens2f0
            - ens2f1
      - name: br-secondary
        type: ovs-bridge
        state: up
        bridge:
          allow-extra-patch-ports: true
          options:
            stp: false
          port:
            - name: bond-tenant
    ovn:
      bridge-mappings:
        - localnet: tenant-a-physnet
          bridge: br-secondary
          state: present
        - localnet: tenant-b-physnet
          bridge: br-secondary
          state: present
```

---

## 3. API Server Publishing

### AWS Demo

HyperShift uses `servicePublishingStrategy.type: LoadBalancer` for the API
server. On AWS, this creates a dedicated NLB (Elastic Load Balancer) per
tenant, each with its own set of public IPs.

### Bare-Metal Equivalent

Install **MetalLB on the hub cluster** to provide `LoadBalancer` service
support. Each tenant's `kube-apiserver` Service gets its own dedicated VIP.

#### Setup Steps

1. Install MetalLB Operator on the hub cluster (same process as on tenant
   clusters in the demo).

2. Create an `IPAddressPool` with a range reserved for tenant API VIPs:

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: tenant-api-pool
  namespace: metallb-system
spec:
  addresses:
    - 192.168.10.50-192.168.10.99
```

3. For production, configure **BGP advertisement** to the data center's
   Top-of-Rack (ToR) switches:

```yaml
apiVersion: metallb.io/v1beta2
kind: BGPPeer
metadata:
  name: tor-switch-1
  namespace: metallb-system
spec:
  myASN: 64512
  peerASN: 64513
  peerAddress: 192.168.10.1
---
apiVersion: metallb.io/v1beta1
kind: BGPAdvertisement
metadata:
  name: tenant-api-advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
    - tenant-api-pool
```

For lab environments, L2 mode (`L2Advertisement`) works without BGP but
is limited to a single-subnet broadcast domain.

4. Create DNS A records for each tenant:

| Record | Value |
|--------|-------|
| `api.tenant-a.example.com` | MetalLB VIP (e.g., 192.168.10.50) |
| `api.tenant-b.example.com` | MetalLB VIP (e.g., 192.168.10.51) |

The `hcp create cluster kubevirt` command uses `--kas-dns-name` to set the
API hostname; no change to the HyperShift workflow.

---

## 4. Ingress Publishing (Tenant Apps / Console)

### AWS Demo

MetalLB inside each tenant cluster announces a VIP on the VLAN network.
Because AWS does not route VLAN traffic, a "mirrored" NLB is created and
DNS CNAME records point `*.apps.tenant-X.<domain>` to it.

### Bare-Metal Equivalent

The physical network routes VLAN traffic natively. MetalLB inside each tenant
cluster announces the ingress VIP directly on the tenant VLAN, and the data
center switch fabric makes it reachable from the corporate network or
internet.

No ELB mirroring is needed. DNS A records point directly to the MetalLB VIP:

| Record | Value |
|--------|-------|
| `*.apps.tenant-a.example.com` | 10.100.30.100 (VLAN 300 VIP) |
| `*.apps.tenant-b.example.com` | 10.100.31.100 (VLAN 301 VIP) |

The MetalLB configuration inside each tenant cluster is **identical** to the
demo -- same `IPAddressPool`, same `L2Advertisement` on the VLAN interface.

---

## 5. Storage for Live Migration

### AWS Demo

| Mode | StorageClass | Access | Live Migratable |
|------|-------------|--------|-----------------|
| Default | `gp3-csi` (EBS) | RWO | No |
| EFS toggle | `efs-sc` (EFS) | RWX | Yes |

EFS is NFS-based and has higher random I/O latency, suitable only for demos.

### Bare-Metal Equivalent

Production bare-metal deployments need **block-based RWX storage** for
live migration. Recommended options:

| Provider | Provisioner | Mode | Notes |
|----------|------------|------|-------|
| **Red Hat ODF** | `openshift-storage.rbd.csi.ceph.com` | Block (RWX) | Recommended; built on Ceph, fully supported |
| NetApp ONTAP | `csi.trident.netapp.io` | Block or File (RWX) | Widely deployed in enterprise/telco |
| Pure Storage | `pxd.portworx.com` | Block (RWX) | High-performance, cloud and on-prem |
| Dell/EMC PowerFlex | `csi-vxflexos.dellemc.com` | Block (RWX) | Scale-out SDS |

After installing the storage provider, create a `StorageClass` and pass it
to `hcp create cluster kubevirt`:

```bash
hcp create cluster kubevirt \
  --root-volume-storage-class <rwx-storage-class> \
  --root-volume-volume-mode Filesystem \
  --root-volume-access-modes ReadWriteMany \
  ...
```

See [PLAN-live-migration-production.md](PLAN-live-migration-production.md)
for the full migration path from demo to production storage.

---

## 6. DNS

### AWS Demo

Route53 manages all DNS records. Setup scripts create records programmatically
via the AWS CLI.

### Bare-Metal Equivalent

Use an enterprise DNS solution (BIND, Infoblox, Active Directory DNS, etc.)
or the **ExternalDNS Operator** for OpenShift to automate record management.

#### Required DNS Records

| Record | Type | Target | Managed By |
|--------|------|--------|------------|
| `api.hub.example.com` | A | Hub API VIP (keepalived or MetalLB) | Installer |
| `*.apps.hub.example.com` | A | Hub ingress VIP | Installer |
| `api.virt.example.com` | A | Infra API VIP | Installer |
| `*.apps.virt.example.com` | A | Infra ingress VIP | Installer |
| `api.tenant-a.example.com` | A | Tenant A API VIP (MetalLB on hub) | Manual or ExternalDNS |
| `*.apps.tenant-a.example.com` | A | Tenant A ingress VIP (MetalLB on tenant) | Manual or ExternalDNS |
| `api.tenant-b.example.com` | A | Tenant B API VIP (MetalLB on hub) | Manual or ExternalDNS |
| `*.apps.tenant-b.example.com` | A | Tenant B ingress VIP (MetalLB on tenant) | Manual or ExternalDNS |

The hub and infra cluster records are created by the OpenShift installer.
Tenant records must be created when each hosted cluster is provisioned.

---

## 7. Components That Remain Identical

These demo components are infrastructure-agnostic and work the same way on
bare-metal without any modification:

| Component | Demo Artifacts | Notes |
|-----------|---------------|-------|
| ACM / MCE / HyperShift Operator | `setup/05-install-acm-mce.sh`, `manifests/hub/` | Operator subscriptions are platform-independent |
| OpenShift Virtualization | `setup/06-install-ocpvirt-nmstate.sh`, `manifests/virt/` | Same operator, same HyperConverged CR |
| NMState Operator | `manifests/virt/nmstate-*.yaml` | Same operator; NNCP just needs the right NIC name |
| OVN localnet NADs | `manifests/tenant-*/nad-*.yaml` | Identical VLAN IDs and localnet topology |
| OVN bridge-mappings (NNCP) | `manifests/virt/nncp-ovs-bridge.yaml` | Same NNCP, different NIC placeholder |
| AdminNetworkPolicy (hub) | `manifests/hub/admin-network-policy.yaml` | Cluster-level, no infra dependency |
| AdminNetworkPolicy (infra) | `manifests/virt/admin-network-policy.yaml` | Cluster-level, no infra dependency |
| EgressFirewall | `manifests/tenant-*/egress-firewall.yaml` | Applied inside tenant clusters |
| HCP creation command | `setup/08-provision-tenant-a.sh`, `setup/09-provision-tenant-b.sh` | Same `hcp create cluster kubevirt` flags |
| Konnectivity mTLS | Auto-managed by HyperShift | Per-tenant TLS certs |
| etcd encryption | Set in `HostedCluster` spec | Per-tenant keys |
| Tenant namespace + labels | `manifests/tenant-*/namespace.yaml` | Same labels, same ANP coverage |

---

## 8. Operational Differences

### Node Lifecycle

| | AWS Demo | Bare-Metal |
|---|---|---|
| Provisioning | `openshift-install` via IPI (cloud API) | Assisted Installer / Agent-based / IPI+BMC |
| Scaling out | Launch new EC2 instance | Rack new server, PXE boot, approve CSR |
| Node replacement | Terminate + re-provision via API | Physical swap, re-image via BMC |
| Decommissioning | `terraform destroy` | Physical removal |

### Upgrades

On bare-metal, node reboots during an OCP upgrade take longer than cloud
instance restarts (typically 10-15 minutes vs. 2-5 minutes). Plan for:

- **N+1 worker rule**: Always have one spare worker node so live-migrated VMs
  have capacity during rolling upgrades.
- **Drain + live-migrate**: `oc adm drain` triggers KubeVirt live migration
  for all VMs on the node. Wait for migrations to complete before rebooting.
- **Firmware updates**: Coordinate BIOS/BMC updates with OCP maintenance
  windows. Some firmware updates require a cold reboot.

### Monitoring

The ACM Observability stack works identically. Add:

- **BMC/IPMI alerting**: Monitor hardware health (fans, PSU, disk SMART) via
  IPMI or Redfish. Integrate with Prometheus via `ipmi_exporter` or vendor
  agents.
- **Switch monitoring**: SNMP or streaming telemetry from the switch fabric
  for VLAN trunk health, port errors, and link state.

---

## 9. SR-IOV as an Alternative to OVN Localnet

The demo uses OVN localnet for tenant VLAN isolation. On bare-metal with
supported NICs, **SR-IOV** is an alternative that provides hardware-level
isolation and near-line-rate performance.

| | OVN Localnet (demo) | SR-IOV |
|---|---|---|
| NIC requirement | Any NIC | Intel E810, Mellanox ConnectX-5+ (switchdev) |
| Isolation | OVN software-defined VLANs | Hardware VFs with VLAN at NIC level |
| Performance | Good (SDN overhead) | Near-line-rate |
| Live migration | Supported | Supported on switchdev-capable NICs |
| Complexity | Lower (no special NIC firmware) | Higher (NIC policy, firmware, VF count limits) |

OVN localnet is recommended for most deployments. SR-IOV is suited for
latency-sensitive workloads (telco NFV, financial trading) where the
additional hardware complexity is justified.

See [PLAN-live-migration-production.md](PLAN-live-migration-production.md)
for SR-IOV configuration details.

---

## 10. Summary: AWS Demo vs. Bare-Metal Production

| Layer | AWS Demo | Bare-Metal Production |
|-------|----------|----------------------|
| **Hub cluster install** | IPI on `m5.2xlarge` | Assisted Installer / Agent-based on standard servers |
| **Infra cluster install** | IPI on `m5.metal` | Assisted Installer / Agent-based on OCP-Virt-certified BM |
| **Secondary NIC** | AWS ENI (created via API) | Physical NIC or bond (pre-cabled to trunk port) |
| **VLAN transport** | Node-local only | Cross-node via physical switch fabric |
| **VLAN gateway** | `iptables` masquerade | Physical router / L3 switch |
| **OVS bridge + NNCP** | Same | Same (different NIC name) |
| **OVN localnet NADs** | Same | Same |
| **Tenant API LB** | AWS NLB (auto-created) | MetalLB on hub cluster (BGP or L2) |
| **Tenant ingress LB** | MetalLB + mirrored NLB | MetalLB (direct, no mirror needed) |
| **DNS** | Route53 | BIND / Infoblox / ExternalDNS |
| **RWX storage** | EFS (NFS, demo-only) | ODF (Ceph RBD), NetApp, Pure Storage |
| **ACM / MCE / HyperShift** | Same | Same |
| **OCP Virt + NMState** | Same | Same |
| **AdminNetworkPolicy** | Same | Same |
| **EgressFirewall** | Same | Same |
| **HCP provisioning** | Same `hcp create` command | Same `hcp create` command |
| **Live migration** | Supported (OVN localnet + EFS) | Supported (OVN localnet + ODF) |
| **VM placement** | Co-located (AWS VLAN limit) | Any node (physical switch trunks VLANs) |
| **Node scaling** | EC2 API | BMC + PXE |
| **Terraform** | VPC, subnets, SGs, EFS, DNS | **Not needed** |

---

## References

- [OpenShift Bare-Metal IPI](https://docs.openshift.com/container-platform/latest/installing/installing_bare_metal_ipi/ipi-install-overview.html)
- [Assisted Installer](https://docs.openshift.com/container-platform/latest/installing/installing_with_agent_based_installer/preparing-to-install-with-agent-based-installer.html)
- [OpenShift Virtualization Hardware Requirements](https://docs.openshift.com/container-platform/latest/virt/install/preparing-cluster-for-virt.html)
- [NMState Operator](https://docs.openshift.com/container-platform/latest/networking/k8s_nmstate/k8s-nmstate-about-the-k8s-nmstate-operator.html)
- [OVN-Kubernetes Secondary Networks](https://docs.openshift.com/container-platform/latest/networking/multiple_networks/configuring-additional-network.html)
- [MetalLB Operator](https://docs.openshift.com/container-platform/latest/networking/metallb/about-metallb.html)
- [OpenShift Data Foundation](https://docs.openshift.com/container-platform/latest/storage/persistent_storage/persistent_storage_local/persistent-storage-using-lvms.html)
- [SR-IOV Network Operator](https://docs.openshift.com/container-platform/latest/networking/hardware_networks/about-sriov.html)
