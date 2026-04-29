# Scenario 1: Explore the Architecture

Walk through the two-cluster HCP topology, showing how control planes and
worker VMs are separated across clusters with full network isolation.

## Talking Points

1. **Two-cluster split**: The hub cluster runs lightweight control plane pods;
   the bare-metal infrastructure cluster runs the actual worker VMs. This is
   the HCP KubeVirt "external infrastructure" topology.

2. **ACM as the single pane of glass**: Open the ACM console on the hub cluster
   and show both hosted clusters as managed clusters.

3. **Namespace isolation on the hub**: Each tenant's control plane runs in its
   own namespace (`clusters-tenant-a`, `clusters-tenant-b`). Show the pods in
   each namespace — kube-apiserver, etcd, konnectivity-server.

4. **Worker VMs on the infra cluster**: Open the OCP Virtualization dashboard.
   Show the running VMs for each tenant.

5. **Secondary network with OVN localnet**: Show the OVS bridge (`br-secondary`)
   and OVN bridge-mapping that provide per-tenant VLAN isolation with live
   migration support.

## Demo Commands

### ACM Console

```bash
# Open the ACM console
export KUBECONFIG=setup/.generated-hub-kubeconfig
oc whoami --show-console
```

### Hosted Clusters Overview

```bash
# List hosted clusters on the hub
export KUBECONFIG=setup/.generated-hub-kubeconfig
oc get hostedclusters -n clusters

# Show control plane pods for Tenant A
oc get pods -n clusters-tenant-a

# Show control plane pods for Tenant B
oc get pods -n clusters-tenant-b
```

### Worker VMs on the Infra Cluster

```bash
# List running VMs
export KUBECONFIG=setup/.generated-virt-kubeconfig
oc get vmi -A

# Show VM details for Tenant A
oc get vmi -n clusters-tenant-a -o wide
```

### Bridge Topology on Bare-Metal Nodes

```bash
# Show bridges and VLAN interfaces on a node
NODE=$(oc get nodes -o jsonpath='{.items[0].metadata.name}')
oc debug node/${NODE} -- chroot /host bash -c "
  echo '=== Bridges ==='
  bridge link show
  echo ''
  echo '=== VLAN interfaces ==='
  ip -d link show type vlan
  echo ''
  echo '=== Bridge br300 ports ==='
  bridge link show master br300
  echo ''
  echo '=== Bridge br301 ports ==='
  bridge link show master br301
"
```

### NNCP Status

```bash
# Verify NNCPs are applied
oc get nncp
oc get nnce
```
