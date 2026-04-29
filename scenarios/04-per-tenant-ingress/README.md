# Scenario 4: Per-Tenant Ingress

Demonstrate that each tenant has a dedicated ingress VIP on its own VLAN,
with no shared ingress infrastructure.

## Talking Points

1. **MetalLB per tenant**: Each hosted cluster runs its own MetalLB instance
   that allocates a VIP from the tenant's VLAN IP range.

2. **L2 advertisement**: The VIP is announced via ARP/NDP only on the
   tenant's VLAN interface — not visible to other tenants.

3. **Wildcard DNS**: `*.apps.tenant-a.<domain>` resolves to Tenant A's VIP;
   `*.apps.tenant-b.<domain>` resolves to Tenant B's VIP.

4. **Complete separation**: An external client connecting to Tenant A's
   application has no network path to Tenant B's ingress.

## Demo Commands

### Deploy Sample Application in Each Tenant

```bash
# Tenant A
export KUBECONFIG=setup/.generated-tenant-a-kubeconfig
oc apply -f scenarios/03-verify-network-isolation/sample-workload.yaml

# Tenant B
export KUBECONFIG=setup/.generated-tenant-b-kubeconfig
oc apply -f scenarios/03-verify-network-isolation/sample-workload.yaml
```

### Verify MetalLB VIPs

```bash
# Tenant A
export KUBECONFIG=setup/.generated-tenant-a-kubeconfig
echo "Tenant A ingress VIP:"
oc get svc metallb-ingress -n openshift-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
echo ""

# Tenant B
export KUBECONFIG=setup/.generated-tenant-b-kubeconfig
echo "Tenant B ingress VIP:"
oc get svc metallb-ingress -n openshift-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
echo ""
```

### Test Ingress Access

```bash
# Tenant A application
curl -sk https://hello-openshift-demo-app.apps.tenant-a.<domain>/

# Tenant B application
curl -sk https://hello-openshift-demo-app.apps.tenant-b.<domain>/
```

### Show MetalLB Configuration

```bash
export KUBECONFIG=setup/.generated-tenant-a-kubeconfig
oc get ipaddresspool -n metallb-system -o yaml
oc get l2advertisement -n metallb-system -o yaml
```

### Automated Test

```bash
./scenarios/04-per-tenant-ingress/test-ingress.sh
```
