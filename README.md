# Hosted Control Planes for Service Providers -- AWS Demo

A full-lifecycle demo showcasing **Hosted Control Planes (HCP)** with
**per-tenant network isolation** on AWS. Two OpenShift clusters work together:
a virtual hub running control planes and a bare-metal infrastructure cluster
running tenant worker VMs on VLAN-isolated OVN localnet networks.

## What This Demo Shows

- **Multi-tenant HCP with KubeVirt**: Each tenant gets an independent
  OpenShift cluster whose control plane runs as pods on the hub and whose
  workers run as VMs on the infrastructure cluster.
- **L2 network isolation via VLANs**: Each tenant's VMs are attached to a
  dedicated OVN localnet network with per-tenant VLAN tagging on a secondary
  network interface -- separate L2 broadcast domains with no cross-tenant path.
- **Per-tenant ingress**: MetalLB inside each hosted cluster provides a
  dedicated VIP on the tenant's VLAN.
- **Security-in-depth**: AdminNetworkPolicy on the hub, HyperShift
  auto-generated NetworkPolicies, EgressFirewall inside each tenant cluster.
- **Live-migratable tenant VMs**: OVN localnet networking allows KubeVirt
  to live-migrate tenant VMs between bare-metal nodes, enabling zero-downtime
  infrastructure upgrades.
- **Multi-version clusters**: Tenants run independent OpenShift versions
  (Tenant A on 4.19, Tenant B on 4.20) from a single hub running 4.21,
  demonstrating version flexibility for service providers.
- **External infrastructure topology**: Control planes on the hub cluster,
  worker VMs on the bare-metal cluster -- a clean separation of management
  and compute.

## Architecture Overview

```
┌──────────────────────────────────────────────────────────┐
│                Hub Cluster  (3× m5.2xlarge)              │
│                                                          │
│  ACM 2.16  ─── MCE / HyperShift Operator                │
│                                                          │
│  ┌─────────────────────┐  ┌─────────────────────┐       │
│  │ clusters-tenant-a   │  │ clusters-tenant-b   │       │
│  │  apiserver, etcd,   │  │  apiserver, etcd,   │       │
│  │  konnectivity-srv   │  │  konnectivity-srv   │       │
│  └─────────┬───────────┘  └──────────┬──────────┘       │
└────────────│──────────────────────────│──────────────────┘
             │ mTLS Konnectivity        │ mTLS Konnectivity
┌────────────▼──────────────────────────▼──────────────────┐
│              Infra Cluster  (3× m5.metal)                │
│                                                          │
│  OCP Virtualization  ───  NMState Operator               │
│                                                          │
│  Secondary NIC (auto-detected, e.g. ens1)                │
│  └── br-secondary (OVS) ── OVN localnet bridge-mapping  │
│      ├── VLAN 300 ── Tenant A VMs (live-migratable)     │
│      └── VLAN 301 ── Tenant B VMs (live-migratable)     │
└──────────────────────────────────────────────────────────┘
```

## Prerequisites

See [docs/prerequisites.md](docs/prerequisites.md) for the full list.

**Quick summary:**

- AWS account with permissions for VPC, EC2 (including `m5.metal`), Route53, IAM
- `aws` CLI configured with credentials
- `openshift-install` (4.21+)
- `oc` CLI
- `hcp` CLI (from MCE / HyperShift)
- `terraform` (1.5+)
- `jq`
- [Red Hat pull secret](http://console.redhat.com/openshift/install/pull-secret) (`pull-secret.json`)
- SSH key pair

## Getting Started

```bash
# 1. Clone this repo
git clone https://github.com/alezzandro/hcp-for-service-providers.git
cd hcp-for-service-providers

# 2. Copy and fill in your lab credentials (AWS keys, domain)
cp credentials.env.example credentials.env
vi credentials.env

# 3. Place your pull secret and SSH key
cp ~/pull-secret.json .
cp ~/.ssh/id_rsa.pub .

# 4. Run the full setup (takes ~90 min)
#    terraform.tfvars is auto-generated from credentials.env
./setup/full-setup.sh

# 5. Show all URLs and credentials
./setup/show-credentials.sh
```

## Setup Scripts

| Script | Purpose |
|--------|---------|
| `00-prereqs.sh` | Validate tools, AWS quotas, required files |
| `01-provision-infrastructure.sh` | Terraform: VPC, subnets, Route53, security groups |
| `02-install-hub-cluster.sh` | Install hub OCP cluster (IPI) |
| `03-install-virt-cluster.sh` | Install bare-metal OCP cluster (IPI, m5.metal) |
| `04-attach-secondary-nic.sh` | Attach secondary ENIs to bare-metal nodes |
| `05-install-acm-mce.sh` | Install ACM + MCE + enable HyperShift |
| `06-install-ocpvirt-nmstate.sh` | Install OCP Virtualization + NMState |
| `06b-install-efs-csi.sh` | Install EFS CSI driver + StorageClass (when toggle is on) |
| `07-configure-secondary-network.sh` | OVS bridge, OVN localnet NADs, IP masquerade |
| `08-provision-tenant-a.sh` | Create Tenant A hosted cluster + MetalLB + DNS |
| `09-provision-tenant-b.sh` | Create Tenant B hosted cluster + MetalLB + DNS |
| `10-apply-security-policies.sh` | AdminNetworkPolicy, EgressFirewall |
| `full-setup.sh` | Run all scripts in order |
| `health-check.sh` | Verify all components are healthy |
| `reset-demo.sh` | Delete tenant clusters, keep base infra |
| `show-credentials.sh` | Print URLs and kubeconfigs |
| `uninstall-demo.sh` | Full teardown (clusters + Terraform) |

## Demo Scenarios

| Scenario | Description |
|----------|-------------|
| [01-explore-architecture](scenarios/01-explore-architecture/) | Tour the two-cluster topology from ACM and OCP consoles |
| [02-provision-new-tenant](scenarios/02-provision-new-tenant/) | Step-by-step creation of a third tenant |
| [03-verify-network-isolation](scenarios/03-verify-network-isolation/) | Prove L2 isolation: cross-tenant traffic is blocked |
| [04-per-tenant-ingress](scenarios/04-per-tenant-ingress/) | Deploy apps, verify per-tenant MetalLB VIPs |
| [05-security-policies](scenarios/05-security-policies/) | Walk through ANP, NetworkPolicy, EgressFirewall |
| [06-live-migration](scenarios/06-live-migration/) | Live-migrate a tenant VM between nodes with zero downtime |

## Live Migration Support

The networking layer is **live-migration ready**. By using OVN-Kubernetes
localnet topology instead of direct host bridge binding, KubeVirt no longer
considers the secondary network interface a migration blocker. OVN manages L2
forwarding at the SDN level and re-programs datapath flows atomically on the
destination node during migration, preserving per-tenant VLAN isolation
throughout.

**Storage toggle for full live migration:** Set `ENABLE_EFS_LIVE_MIGRATION="true"`
in `credentials.env` before running setup. This provisions an AWS EFS filesystem
and configures tenant VMs with RWX (`ReadWriteMany`) root disks via the `efs-sc`
StorageClass, satisfying KubeVirt's requirement for shared storage during live
migration. With this toggle enabled, `KubeVirtNodesLiveMigratable` reports `True`.

When the toggle is `"false"` (default), VMs use AWS EBS (`gp3-csi` / RWO) and
the condition shows `DisksNotLiveMigratable`. The networking layer remains
migration-ready regardless.

> **Production note:** EFS (NFS) is suitable for demos. For production, use
> **Red Hat OpenShift Data Foundation** (Ceph RBD, Block mode, RWX), NetApp
> ONTAP, Pure Storage, or other certified RWX-capable storage.

See [Scenario 06 -- Live Migration](scenarios/06-live-migration/) for a
step-by-step walkthrough and [PLAN-live-migration-production.md](docs/PLAN-live-migration-production.md)
for the full production topology.

## Known Limitations

**Storage blocks live migration by default.** With `ENABLE_EFS_LIVE_MIGRATION="false"`
(the default), VM root disk PVCs use `gp3-csi` (AWS EBS / `ReadWriteOnce`).
Live migration requires `ReadWriteMany` storage. Set the toggle to `"true"` to
enable EFS-backed RWX storage automatically.

**AWS VLAN constraint.** VLAN-tagged frames do not traverse AWS VPC networking.
Tenant VMs for the same customer are co-located on the same bare-metal node
using pod affinity. In production on physical infrastructure, switches trunk
VLANs across all nodes, removing this constraint.

**EFS performance.** When EFS is enabled, VM boot times may be longer due to
NFS latency compared to EBS. This is acceptable for demos. Production
deployments should use block-based RWX storage (e.g., ODF/Ceph RBD) for full
I/O performance.

## AWS Cost Estimate

| Component | Instance Type | Count | Cost/hr |
|-----------|---------------|-------|---------|
| Hub cluster | m5.2xlarge | 3 | ~$1.15 |
| Infra cluster | m5.metal | 3 | ~$13.82 |
| Networking/EBS | — | — | ~$1–2 |
| **Total** | | | **~$16/hr** |

**Destroy the environment when not in use.** See [docs/cost-estimate.md](docs/cost-estimate.md).

## Documentation

- [Architecture](docs/architecture.md)
- [Prerequisites](docs/prerequisites.md)
- [AWS Network Design](docs/aws-network-design.md)
- [Cost Estimate](docs/cost-estimate.md)
- [Live Migration Production Plan](docs/PLAN-live-migration-production.md)

## References

- [OCP 4.21 -- Hosted Control Planes](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/hosted_control_planes/)
- [HCP KubeVirt External Infrastructure](https://hypershift.pages.dev/how-to/kubevirt/external-infrastructure/)
- [HCP KubeVirt Networking Guide](https://examples.openshift.pub/cluster-installation/hosted-control-plane/kubevirt-networking/)
- [ACM 2.16 -- Fleet Management](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/multicluster_engine_operator_with_red_hat_advanced_cluster_management/)

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for details.

This demo is provided as-is for educational and demonstration purposes.
No warranty is expressed or implied. Destroy AWS resources when finished to
avoid unexpected charges.
