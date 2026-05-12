# Scenario 2: Provision a New Tenant

Demonstrate the repeatable process of creating a new tenant hosted cluster
with VLAN isolation, dedicated ingress, and security policies.

## Talking Points

1. **Repeatable process**: Each new tenant follows the same pattern:
   update NNCP bridge-mapping -> namespace + OVN localnet NAD -> hcp create ->
   MetalLB -> DNS. The OVS bridge is already in place from the base setup.

2. **No shared infrastructure**: The new tenant gets its own VLAN (via OVN
   localnet), CIDR ranges, MetalLB VIP, and DNS entries.

3. **Minutes, not days**: Provisioning a full OpenShift cluster for a new
   B2B customer takes minutes, not the weeks required for a dedicated
   physical cluster.

4. **Independent lifecycle**: The new tenant can run a different OCP version,
   upgrade independently, and install their own operators.

## Demo Steps

This scenario provisions a third tenant ("tenant-c") with VLAN 302.

### Step 1: Create Namespace and OVN LocalNet NAD (on infra cluster)

The OVS bridge (`br-secondary`) is already configured from script 07. Each new
tenant needs a bridge-mapping entry added to the NNCP, a namespace, and a NAD
with a unique localnet name and VLAN ID.

First, add the bridge-mapping to the existing NNCP:

```bash
export KUBECONFIG=setup/.generated-virt-kubeconfig

# Patch the NNCP to add the new tenant's bridge-mapping
oc patch nncp secondary-nic-ovs-bridge --type=merge -p '
spec:
  desiredState:
    ovn:
      bridge-mappings:
        - localnet: tenant-a-physnet
          bridge: br-secondary
          state: present
        - localnet: tenant-b-physnet
          bridge: br-secondary
          state: present
        - localnet: tenant-c-physnet
          bridge: br-secondary
          state: present
'

# Wait for NNCP to reconcile on all nodes
oc wait nncp secondary-nic-ovs-bridge --for=condition=Available --timeout=120s
```

Then create the namespace and NAD:

```bash
export KUBECONFIG=setup/.generated-virt-kubeconfig

oc create namespace clusters-tenant-c

cat <<'EOF' | oc apply -f -
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: nad-vlan302
  namespace: clusters-tenant-c
spec:
  config: |-
    {
      "cniVersion": "0.3.1",
      "name": "tenant-c-physnet",
      "type": "ovn-k8s-cni-overlay",
      "topology": "localnet",
      "netAttachDefName": "clusters-tenant-c/nad-vlan302",
      "vlanID": 302,
      "subnets": "10.100.32.0/24",
      "excludeSubnets": "10.100.32.0/32,10.100.32.1/32,10.100.32.255/32",
      "mtu": 1500
    }
EOF
```

### Step 2: Create the Hosted Cluster (on hub)

```bash
export KUBECONFIG=setup/.generated-hub-kubeconfig

hcp create cluster kubevirt \
  --name tenant-c \
  --namespace clusters \
  --node-pool-replicas 2 \
  --pull-secret pull-secret.json \
  --ssh-key id_rsa.pub \
  --memory "16Gi" \
  --cores 4 \
  --release-image quay.io/openshift-release-dev/ocp-release:4.20.0-multi \
  --cluster-cidr "10.140.0.0/14" \
  --service-cidr "172.33.0.0/16" \
  --additional-network "name:clusters-tenant-c/nad-vlan302" \
  --infra-kubeconfig-file setup/.generated-infra-sa-kubeconfig-c \
  --infra-namespace clusters-tenant-c \
  --kas-dns-name "api.tenant-c.<base-domain>"

# Monitor progress
oc get hostedcluster tenant-c -n clusters -w
```

### Step 3: Install MetalLB + DNS

After the hosted cluster is available, install MetalLB inside it and create
the DNS record (similar to setup scripts 08/09).

**Note**: On OCP 4.19.12+ and 4.20.18+, the HyperShift operator correctly
populates the `FRR_K8S_IMAGE` environment variable, so MetalLB installation
no longer causes a degraded Network CO. If using older z-streams (e.g.
4.19.0, 4.20.0), you may need to remove `additionalRoutingCapabilities`
after MetalLB installation.

### Cleanup

```bash
./scenarios/02-provision-new-tenant/cleanup.sh
```
