# Scenario 3: Verify Network Isolation

Prove that tenants are isolated at L2. Traffic within a tenant works;
cross-tenant traffic is blocked.

## Talking Points

1. **L2 isolation**: Tenant A VMs are on OVN localnet VLAN 300. Tenant B
   VMs are on OVN localnet VLAN 301. Separate broadcast domains.

2. **No cross-tenant path**: A pod in Tenant A cannot reach Tenant B's
   network -- different VLAN, different OVN logical switch, different CIDR.

3. **Intra-tenant works**: Pods within the same tenant communicate normally
   via the hosted cluster's OVN-Kubernetes overlay.

4. **Control plane isolation**: HyperShift NetworkPolicies + AdminNetworkPolicy
   prevent cross-namespace traffic between control planes on the hub.

## Demo Commands

### Test Intra-Tenant Connectivity (should work)

```bash
export KUBECONFIG=setup/.generated-tenant-a-kubeconfig

# Deploy a test pod
oc run test-ping --image=registry.access.redhat.com/ubi9/ubi-minimal \
  --restart=Never -- sleep 3600

# Wait for it to be Running
oc wait pod/test-ping --for=condition=Ready --timeout=120s

# Get a node IP (from the hosted cluster's perspective)
NODE_IP=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "Node IP: ${NODE_IP}"

# Ping from the test pod to the node (same tenant network)
oc exec test-ping -- ping -c 3 ${NODE_IP}
```

### Test Cross-Tenant Connectivity (should fail)

```bash
# Get a Tenant B node IP
export KUBECONFIG=setup/.generated-tenant-b-kubeconfig
TENANT_B_NODE_IP=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "Tenant B node IP: ${TENANT_B_NODE_IP}"

# Try to reach Tenant B's node from Tenant A's pod (should timeout/fail)
export KUBECONFIG=setup/.generated-tenant-a-kubeconfig
oc exec test-ping -- ping -c 3 -W 5 ${TENANT_B_NODE_IP} || echo "BLOCKED: Cannot reach Tenant B (expected)"
```

### Verify OVN Localnet Isolation on the Infra Cluster

```bash
export KUBECONFIG=setup/.generated-virt-kubeconfig

# Show OVS bridge and port mappings
NODE=$(oc get nodes -o jsonpath='{.items[0].metadata.name}')

oc debug node/${NODE} -- chroot /host bash -c "
  echo '=== OVS bridge ports ==='
  ovs-vsctl show | grep -A2 br-secondary
  echo ''
  echo '=== OVN localnet port bindings ==='
  ovs-vsctl list interface | grep -E 'name|external_ids' | head -20
"
```

### Automated Test

```bash
./scenarios/03-verify-network-isolation/test-isolation.sh
```

### Cleanup

```bash
export KUBECONFIG=setup/.generated-tenant-a-kubeconfig
oc delete pod test-ping --ignore-not-found
```
