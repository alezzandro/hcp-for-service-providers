# Scenario 5: Security Policies

Walk through the defense-in-depth security layers: AdminNetworkPolicy on the
hub and infra clusters, HyperShift auto-generated NetworkPolicies, and
EgressFirewall inside tenant clusters.

## Talking Points

1. **AdminNetworkPolicy (ANP) on the Hub**: Cluster-wide rules on the hub that
   tenants cannot override. The ANP denies cross-namespace traffic between
   control plane namespaces and restricts egress to only required paths.

2. **AdminNetworkPolicy (ANP) on the Infra Cluster**: Denies all traffic
   between tenant-labelled namespaces on the OVN primary overlay. Platform
   namespaces (kubelet, DNS, Konnectivity, virt-handler) remain reachable.
   Intra-tenant VM communication uses the secondary VLAN network, so the
   overlay deny has no operational impact.

3. **HyperShift NetworkPolicies**: Automatically generated per control plane
   namespace. These are the first line of defense, but tenants with namespace
   admin could theoretically modify them — ANP provides the non-bypassable
   layer.

4. **EgressFirewall**: Inside each tenant cluster, restricts outbound traffic
   to only DNS (UDP 53) and HTTPS (443). Everything else is denied.

5. **Layered approach**: ANP protects the hub and infra clusters,
   NetworkPolicies protect the control plane namespaces, OVN localnet VLANs
   protect the data plane at L2, the infra ANP blocks cross-tenant overlay
   traffic, and EgressFirewall protects the egress path.

## Demo Commands

### AdminNetworkPolicy on the Hub

```bash
export KUBECONFIG=setup/.generated-hub-kubeconfig

# Show the ANP
oc get adminnetworkpolicy hcp-control-plane-isolation -o yaml

# Show which namespaces it applies to
oc get namespaces -l hypershift.openshift.io/hosted-control-plane=true
```

### AdminNetworkPolicy on the Infra Cluster

```bash
export KUBECONFIG=setup/.generated-virt-kubeconfig

# Show the ANP
oc get adminnetworkpolicy tenant-vm-isolation -o yaml

# Show which namespaces it applies to
oc get namespaces -l tenant

# Verify: cross-tenant overlay traffic is blocked
oc run probe --image=registry.access.redhat.com/ubi9/ubi-minimal \
  --restart=Never -n clusters-tenant-a -- sleep 300
oc wait pod/probe -n clusters-tenant-a --for=condition=Ready --timeout=60s

TENANT_B_VM_IP=$(oc get pods -n clusters-tenant-b -l kubevirt.io=virt-launcher \
  -o jsonpath='{.items[0].status.podIP}')

# Should timeout (exit code 28) — cross-tenant traffic is denied
oc exec -n clusters-tenant-a probe -- \
  curl -sk --connect-timeout 5 "https://${TENANT_B_VM_IP}:10250/" \
  || echo " (blocked — expected)"

oc delete pod probe -n clusters-tenant-a --ignore-not-found
```

### HyperShift Auto-Generated NetworkPolicies

```bash
# Show NetworkPolicies in Tenant A's control plane namespace
oc get networkpolicy -n clusters-tenant-a

# Describe a specific policy
oc describe networkpolicy -n clusters-tenant-a
```

### EgressFirewall in Tenant Clusters

```bash
export KUBECONFIG=setup/.generated-tenant-a-kubeconfig

# Show the EgressFirewall
oc get egressfirewall -n customer-workloads -o yaml

# Test: HTTPS should work
oc run egress-test --image=registry.access.redhat.com/ubi9/ubi-minimal \
  --restart=Never -- sleep 3600
oc wait pod/egress-test --for=condition=Ready --timeout=60s

# Allowed: HTTPS (port 443)
oc exec egress-test -n customer-workloads -- \
  curl -sk --connect-timeout 5 https://www.redhat.com/ -o /dev/null -w "%{http_code}" \
  && echo " (allowed)"

# Denied: HTTP (port 80) — not in the allow list
oc exec egress-test -n customer-workloads -- \
  curl -sk --connect-timeout 5 http://example.com/ -o /dev/null -w "%{http_code}" \
  || echo " (blocked — expected)"

# Cleanup
oc delete pod egress-test -n customer-workloads --ignore-not-found
```

### etcd Encryption

```bash
export KUBECONFIG=setup/.generated-hub-kubeconfig

# Show etcd encryption configuration
oc get hostedcluster tenant-a -n clusters \
  -o jsonpath='{.spec.secretEncryption}' | jq .

oc get hostedcluster tenant-b -n clusters \
  -o jsonpath='{.spec.secretEncryption}' | jq .
```

### Konnectivity TLS Certificates

```bash
# Show unique Konnectivity certs per tenant
oc get secret -n clusters-tenant-a | grep konnectivity
oc get secret -n clusters-tenant-b | grep konnectivity
```
