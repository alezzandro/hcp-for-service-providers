# AWS Network Design

## VPC Layout

Both clusters share a single VPC to simplify networking between the hub and
infrastructure clusters (Konnectivity traffic, management operations).

```
VPC: 10.0.0.0/16
│
├── Public Subnets (load balancers, NAT gateway)
│   ├── 10.0.1.0/24  (AZ-a)
│   ├── 10.0.2.0/24  (AZ-b)
│   └── 10.0.3.0/24  (AZ-c)
│
├── Private Subnets (cluster nodes)
│   ├── 10.0.11.0/24 (AZ-a)
│   ├── 10.0.12.0/24 (AZ-b)
│   └── 10.0.13.0/24 (AZ-c)
│
└── Tenant Subnets (secondary ENI for bare-metal nodes)
    ├── 10.0.100.0/24 (AZ-a)
    ├── 10.0.101.0/24 (AZ-b)
    └── 10.0.102.0/24 (AZ-c)
```

## Subnet Purpose

### Public Subnets

- Internet-facing load balancers created by `openshift-install`
- NAT gateway for outbound internet access from private subnets
- Tagged for OCP IPI discovery

### Private Subnets

- Hub cluster nodes (3× `m5.2xlarge`)
- Infrastructure cluster nodes (3× `m5.metal`)
- Both clusters' nodes reside in the same private subnets for simplicity;
  OCP IPI creates its own security groups to isolate them

### Tenant Subnets

- Secondary ENIs for bare-metal nodes
- These ENIs carry the OVS bridge and OVN localnet networks for tenant VM traffic
- A separate route table with a NAT gateway for outbound connectivity
  (simulates the VLAN gateway from the reference architecture)

## Secondary Network Interface

Each bare-metal node gets a secondary ENI attached post-install:

```
Primary ENI (eth0/ens5)          Secondary ENI (ens6)
│                                │
├── OCP cluster SDN              └── br-secondary (OVS bridge)
├── Node-to-node (Geneve)            │
├── API server                       ├── OVN localnet VLAN 300 (Tenant A)
└── Management traffic               └── OVN localnet VLAN 301 (Tenant B)
```

### Source/Destination Check

Source/destination check is **disabled** on the secondary ENIs. This is
required because:
- KubeVirt VMs have MAC addresses different from the ENI's MAC
- The hosted cluster's OVN overlay generates encapsulated traffic
- MetalLB VIPs are virtual addresses not assigned to the ENI

### IP Masquerade (VLAN Gateway Simulation)

Since VLAN-tagged frames do not traverse AWS VPC networking, VMs on OVN
localnet networks have no direct route to the internet. OVN handles L2
forwarding within each VLAN, but outbound NAT to the internet still requires
iptables masquerade rules on each bare-metal node:

```bash
# Tenant A: NAT traffic from VLAN 300 through primary interface
iptables -t nat -A POSTROUTING -s 10.100.30.0/24 -o ens5 -j MASQUERADE

# Tenant B: NAT traffic from VLAN 301 through primary interface
iptables -t nat -A POSTROUTING -s 10.100.31.0/24 -o ens5 -j MASQUERADE

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1
```

This simulates the VLAN gateway from the reference architecture. In
production, each VLAN would have a physical gateway on the data center
network.

## AWS Limitations vs. Production

| Aspect | Production (Physical DC) | AWS Demo |
|--------|--------------------------|----------|
| VLAN trunking | Physical switches trunk VLANs to all nodes | VLANs are node-local only |
| Cross-node L2 | VMs on same VLAN communicate across nodes | VMs must be co-located on same node |
| VLAN gateway | Physical router per VLAN | iptables MASQUERADE on node |
| DHCP | External DHCP server per VLAN | OVN built-in IPAM |
| Secondary NIC | Bonded NIC (bond0) with trunk | AWS secondary ENI |

These are documented limitations of the AWS demo environment. The OVN
localnet configuration, NADs, NNCPs, and MetalLB setup are identical to
production -- only the underlying transport differs.

## Security Groups

### Cluster Nodes (hub + infra)

Managed primarily by `openshift-install`. Additional rules added for:
- Cross-cluster API access (hub ↔ infra, port 6443)
- Konnectivity Routes (port 443 from infra to hub ingress)

### Tenant Network

A dedicated security group for the secondary ENIs:
- Allow all traffic within the tenant subnet (for bridge/VLAN traffic)
- Allow outbound to NAT gateway (for Konnectivity, image pulls)
- Deny inbound from outside the VPC

## DNS

Route53 records created for the demo:

| Record | Target |
|--------|--------|
| `api.hub.<domain>` | Hub API load balancer (created by IPI) |
| `*.apps.hub.<domain>` | Hub ingress load balancer (created by IPI) |
| `api.virt.<domain>` | Infra API load balancer (created by IPI) |
| `*.apps.virt.<domain>` | Infra ingress load balancer (created by IPI) |
| `api.tenant-a.<domain>` | Tenant A KAS ELB on hub (CNAME) |
| `*.apps.tenant-a.<domain>` | Tenant A mirrored ingress ELB on infra (CNAME) |
| `api.tenant-b.<domain>` | Tenant B KAS ELB on hub (CNAME) |
| `*.apps.tenant-b.<domain>` | Tenant B mirrored ingress ELB on infra (CNAME) |
