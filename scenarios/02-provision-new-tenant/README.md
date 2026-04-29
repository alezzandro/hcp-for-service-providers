# Scenario 2: Provision a New Tenant

Demonstrate the repeatable process of creating a new tenant hosted cluster
with VLAN isolation, dedicated ingress, and security policies.

## Talking Points

1. **Repeatable process**: Each new tenant follows the same 5-step pattern:
   bridge-mapping -> OVN localnet NAD -> hcp create -> MetalLB -> DNS. The OVS
   bridge is already in place from the base infrastructure setup.

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
tenant needs a bridge-mapping added on every node, a namespace, and a NAD with
a unique localnet name and VLAN ID.

First, add the bridge-mapping on each node:

```bash
for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
  CURRENT=$(oc debug "node/${node}" --quiet -- chroot /host \
    ovs-vsctl get Open_vSwitch . external-ids:ovn-bridge-mappings)
  CURRENT="${CURRENT//\"/}"
  oc debug "node/${node}" --quiet -- chroot /host \
    ovs-vsctl set Open_vSwitch . \
    external-ids:ovn-bridge-mappings="${CURRENT},tenant-c-physnet:br-secondary"
done
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

**Important**: After installing MetalLB, the CNO in HCP mode will set
`additionalRoutingCapabilities.providers: [FRR]` but lacks the `FRR_K8S_IMAGE`
environment variable, causing a degraded network CO. Since we only use L2
mode, remove this setting immediately after MetalLB installation:

```bash
export KUBECONFIG=setup/.generated-tenant-c-kubeconfig
oc patch network.operator cluster --type=json \
  -p='[{"op": "remove", "path": "/spec/additionalRoutingCapabilities"}]'
```

### Cleanup

```bash
./scenarios/02-provision-new-tenant/cleanup.sh
```
