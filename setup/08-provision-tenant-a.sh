#!/usr/bin/env bash
# 08-provision-tenant-a.sh -- Create Tenant A hosted cluster, MetalLB, and DNS.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP_DIR="${DEMO_DIR}/setup"
ENV_FILE="${SETUP_DIR}/.generated-infra.env"
HUB_KUBECONFIG="${SETUP_DIR}/.generated-hub-kubeconfig"
VIRT_KUBECONFIG="${SETUP_DIR}/.generated-virt-kubeconfig"
TENANT_KUBECONFIG="${SETUP_DIR}/.generated-tenant-a-kubeconfig"

source "${DEMO_DIR}/credentials.env"
source "${ENV_FILE}"

TENANT_NAME="tenant-a"
INFRA_NAMESPACE="clusters-${TENANT_NAME}"
CLUSTER_CIDR="10.132.0.0/14"
SERVICE_CIDR="172.31.0.0/16"
METALLB_VIP="10.100.30.100"
RELEASE_IMAGE="quay.io/openshift-release-dev/ocp-release:4.19.0-multi"

echo "=== Provisioning Tenant A hosted cluster ==="

# Ensure infra namespace and RBAC exist on the virt cluster
echo "--- Setting up infra namespace, NAD, and RBAC ---"
export KUBECONFIG="${VIRT_KUBECONFIG}"
oc apply -f "${DEMO_DIR}/manifests/tenant-a/namespace.yaml"
oc apply -f "${DEMO_DIR}/manifests/tenant-a/nad-"*.yaml

# Create a service account on the virt cluster for HyperShift external infra
if ! oc get sa hcp-infra -n "${INFRA_NAMESPACE}" &>/dev/null; then
  oc create sa hcp-infra -n "${INFRA_NAMESPACE}"
fi
oc apply -f "${DEMO_DIR}/manifests/hub/infra-rbac.yaml" -n "${INFRA_NAMESPACE}"

# Generate a kubeconfig for the infra service account
INFRA_TOKEN=$(oc create token hcp-infra -n "${INFRA_NAMESPACE}" --duration=87600h 2>/dev/null || \
  oc sa get-token hcp-infra -n "${INFRA_NAMESPACE}" 2>/dev/null || true)
INFRA_SERVER=$(oc whoami --show-server)

INFRA_KUBECONFIG_FILE="${SETUP_DIR}/.generated-infra-sa-kubeconfig"
cat > "${INFRA_KUBECONFIG_FILE}" <<EOF
apiVersion: v1
kind: Config
clusters:
  - cluster:
      server: ${INFRA_SERVER}
      insecure-skip-tls-verify: true
    name: infra
contexts:
  - context:
      cluster: infra
      namespace: ${INFRA_NAMESPACE}
      user: hcp-infra
    name: infra
current-context: infra
users:
  - name: hcp-infra
    user:
      token: ${INFRA_TOKEN}
EOF

# Create the hosted cluster on the hub (skip if already exists)
echo "--- Creating hosted cluster on hub ---"
export KUBECONFIG="${HUB_KUBECONFIG}"

if oc get hostedcluster "${TENANT_NAME}" -n clusters &>/dev/null; then
  echo "    HostedCluster ${TENANT_NAME} already exists. Skipping creation."
else
  EFS_FLAGS=()
  if [[ "${ENABLE_EFS_LIVE_MIGRATION:-false}" == "true" ]]; then
    EFS_FLAGS=(
      --root-volume-storage-class efs-sc
      --root-volume-volume-mode Filesystem
      --root-volume-access-modes ReadWriteMany
    )
    echo "    EFS live-migration mode enabled."
  fi

  hcp create cluster kubevirt \
    --name "${TENANT_NAME}" \
    --namespace clusters \
    --node-pool-replicas 2 \
    --node-upgrade-type InPlace \
    --pull-secret "${DEMO_DIR}/pull-secret.json" \
    --ssh-key "${DEMO_DIR}/id_rsa.pub" \
    --memory "16Gi" \
    --cores 4 \
    --root-volume-size 60 \
    --release-image "${RELEASE_IMAGE}" \
    --etcd-storage-class gp3-csi \
    --cluster-cidr "${CLUSTER_CIDR}" \
    --service-cidr "${SERVICE_CIDR}" \
    --additional-network "name:${INFRA_NAMESPACE}/nad-vlan300" \
    --infra-kubeconfig-file "${INFRA_KUBECONFIG_FILE}" \
    --infra-namespace "${INFRA_NAMESPACE}" \
    --base-domain "${BASE_DOMAIN}" \
    --kas-dns-name "api.${TENANT_NAME}.${BASE_DOMAIN}" \
    "${EFS_FLAGS[@]}"
fi

echo "--- Waiting for hosted cluster to be available ---"
echo "    (this may take 15-20 minutes)"
for i in $(seq 1 60); do
  AVAILABLE=$(oc get hostedcluster "${TENANT_NAME}" -n clusters \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "Unknown")
  if [[ "${AVAILABLE}" == "True" ]]; then
    echo "    Hosted cluster ${TENANT_NAME} is Available."
    break
  fi
  PROGRESS=$(oc get hostedcluster "${TENANT_NAME}" -n clusters \
    -o jsonpath='{.status.version.history[0].state}' 2>/dev/null || echo "Unknown")
  echo "    Progress: ${PROGRESS}, Available: ${AVAILABLE} (${i}/60)"
  sleep 30
done

echo "--- Extracting tenant kubeconfig ---"
hcp create kubeconfig --name "${TENANT_NAME}" --namespace clusters > "${TENANT_KUBECONFIG}"

echo "--- Waiting for tenant worker nodes to be Ready ---"
export KUBECONFIG="${TENANT_KUBECONFIG}"
for i in $(seq 1 60); do
  READY_NODES=$(oc get nodes --no-headers 2>/dev/null | grep -c ' Ready' || true)
  READY_NODES="${READY_NODES:-0}"
  if [[ "${READY_NODES}" -ge 1 ]]; then
    echo "    ${READY_NODES} node(s) Ready."
    break
  fi
  echo "    Waiting for nodes... (${i}/60)"
  sleep 30
done

echo "--- Waiting for OLM to be available in tenant cluster ---"
for i in $(seq 1 30); do
  if oc api-resources 2>/dev/null | grep -q operatorgroups; then
    echo "    OLM CRDs available."
    break
  fi
  echo "    Waiting for OLM... (${i}/30)"
  sleep 20
done

echo "--- Installing MetalLB operator subscription ---"
oc apply -f "${DEMO_DIR}/manifests/tenant-a/metallb-ingress.yaml" --server-side=true --force-conflicts 2>&1 || true

echo "--- Waiting for MetalLB operator ---"
for i in $(seq 1 30); do
  CSV=$(oc get csv -n metallb-system -o name 2>/dev/null | grep metallb || true)
  if [[ -n "${CSV}" ]]; then
    PHASE=$(oc get "${CSV}" -n metallb-system -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "${PHASE}" == "Succeeded" ]]; then
      echo "    MetalLB operator is Succeeded."
      break
    fi
  fi
  echo "    Waiting... (${i}/30)"
  sleep 20
done

echo "--- Applying MetalLB instance and IP pools ---"
oc apply -f "${DEMO_DIR}/manifests/tenant-a/metallb-ingress.yaml"

# Workaround: In HCP mode the CNO sets additionalRoutingCapabilities FRR when
# MetalLB is present but lacks the FRR_K8S_IMAGE env var, causing a degraded
# network CO.  Since we use L2 mode only, FRR-K8s is not needed.
# The CNO may re-add the field after MetalLB reconciles, so we loop until the
# network CO reports Degraded=False (up to ~4 minutes).
echo "--- Removing additionalRoutingCapabilities (HCP/MetalLB workaround) ---"
export KUBECONFIG="${TENANT_KUBECONFIG}"
for attempt in $(seq 1 24); do
  ARC=$(oc get network.operator cluster -o jsonpath='{.spec.additionalRoutingCapabilities}' 2>/dev/null || true)
  if [[ -n "${ARC}" && "${ARC}" != "{}" ]]; then
    oc patch network.operator cluster --type=json \
      -p='[{"op": "remove", "path": "/spec/additionalRoutingCapabilities"}]' 2>/dev/null && \
      echo "    additionalRoutingCapabilities removed (attempt ${attempt})."
  fi
  DEG=$(oc get co network -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || true)
  if [[ "${DEG}" == "False" ]]; then
    echo "    Network CO is healthy."
    break
  fi
  echo "    Network CO Degraded=${DEG}, rechecking... (${attempt}/24)"
  sleep 10
done

echo "--- Creating Route53 DNS records for Tenant A ---"
export KUBECONFIG="${HUB_KUBECONFIG}"

# API record: CNAME to the KAS LoadBalancer on the hub
KAS_ELB=$(oc get svc kube-apiserver -n "clusters-${TENANT_NAME}" \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "    KAS ELB: ${KAS_ELB}"

aws route53 change-resource-record-sets \
  --hosted-zone-id "${ROUTE53_ZONE_ID}" \
  --change-batch "{
    \"Changes\": [{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"api.${TENANT_NAME}.${BASE_DOMAIN}\",
        \"Type\": \"CNAME\",
        \"TTL\": 300,
        \"ResourceRecords\": [{\"Value\": \"${KAS_ELB}\"}]
      }
    }]
  }" --region "${AWS_REGION}"

# Apps record: CNAME to the HyperShift-mirrored ingress ELB on the infra cluster
export KUBECONFIG="${VIRT_KUBECONFIG}"
echo "--- Waiting for mirrored ingress ELB on infra cluster ---"
APPS_ELB=""
for i in $(seq 1 30); do
  APPS_ELB=$(oc get svc -n "${INFRA_NAMESPACE}" \
    -l "cluster.x-k8s.io/tenant-service-name=metallb-ingress" \
    -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [[ -n "${APPS_ELB}" ]]; then
    echo "    Apps ELB: ${APPS_ELB}"
    break
  fi
  echo "    Waiting for mirrored ELB... (${i}/30)"
  sleep 20
done

if [[ -z "${APPS_ELB}" ]]; then
  echo "    WARNING: Mirrored ELB not found. Falling back to MetalLB VIP for apps DNS."
  APPS_ELB=""
fi

# Create EndpointSlice for the mirrored service (HyperShift does not populate it automatically)
MIRROR_SVC_NAME=$(oc get svc -n "${INFRA_NAMESPACE}" \
  -l "cluster.x-k8s.io/tenant-service-name=metallb-ingress" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -n "${MIRROR_SVC_NAME}" ]]; then
  echo "--- Creating EndpointSlice for mirrored ingress service ---"
  MIRROR_HTTP_PORT=$(oc get svc "${MIRROR_SVC_NAME}" -n "${INFRA_NAMESPACE}" \
    -o jsonpath='{.spec.ports[?(@.name=="http")].targetPort}')
  MIRROR_HTTPS_PORT=$(oc get svc "${MIRROR_SVC_NAME}" -n "${INFRA_NAMESPACE}" \
    -o jsonpath='{.spec.ports[?(@.name=="https")].targetPort}')

  VM_IPS=$(oc get vmi -n "${INFRA_NAMESPACE}" -o jsonpath='{.items[*].status.interfaces[0].ipAddress}')
  ENDPOINT_ENTRIES=""
  for ip in ${VM_IPS}; do
    ENDPOINT_ENTRIES="${ENDPOINT_ENTRIES}
  - addresses: [\"${ip}\"]
    conditions:
      ready: true"
  done

  cat <<EPEOF | oc apply -f -
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: ${MIRROR_SVC_NAME}-ingress-eps
  namespace: ${INFRA_NAMESPACE}
  labels:
    kubernetes.io/service-name: ${MIRROR_SVC_NAME}
addressType: IPv4
endpoints:${ENDPOINT_ENTRIES}
ports:
  - name: http
    port: ${MIRROR_HTTP_PORT}
    protocol: TCP
  - name: https
    port: ${MIRROR_HTTPS_PORT}
    protocol: TCP
EPEOF
fi

export KUBECONFIG="${HUB_KUBECONFIG}"

if [[ -n "${APPS_ELB}" ]]; then
  aws route53 change-resource-record-sets \
    --hosted-zone-id "${ROUTE53_ZONE_ID}" \
    --change-batch "{
      \"Changes\": [{
        \"Action\": \"UPSERT\",
        \"ResourceRecordSet\": {
          \"Name\": \"*.apps.${TENANT_NAME}.${BASE_DOMAIN}\",
          \"Type\": \"CNAME\",
          \"TTL\": 300,
          \"ResourceRecords\": [{\"Value\": \"${APPS_ELB}\"}]
        }
      }]
    }" --region "${AWS_REGION}"
else
  aws route53 change-resource-record-sets \
    --hosted-zone-id "${ROUTE53_ZONE_ID}" \
    --change-batch "{
      \"Changes\": [{
        \"Action\": \"UPSERT\",
        \"ResourceRecordSet\": {
          \"Name\": \"*.apps.${TENANT_NAME}.${BASE_DOMAIN}\",
          \"Type\": \"A\",
          \"TTL\": 300,
          \"ResourceRecords\": [{\"Value\": \"${METALLB_VIP}\"}]
        }
      }]
    }" --region "${AWS_REGION}"
fi

# Wait for ManagedCluster auto-import
echo "--- Waiting for ACM auto-import of ${TENANT_NAME} ---"
for i in $(seq 1 30); do
  MC_AVAIL=$(oc get managedcluster "${TENANT_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status}' 2>/dev/null || true)
  if [[ "${MC_AVAIL}" == "True" ]]; then
    echo "    ManagedCluster ${TENANT_NAME} imported and available."
    break
  fi
  echo "    Waiting for ManagedCluster... (${i}/30)"
  sleep 20
done

echo ""
echo "Tenant A provisioned."
echo "  Kubeconfig:  ${TENANT_KUBECONFIG}"
echo "  API Server:  https://api.${TENANT_NAME}.${BASE_DOMAIN}:6443"
echo "  Console:     https://console-openshift-console.apps.${TENANT_NAME}.${BASE_DOMAIN}"
echo "  MetalLB VIP: ${METALLB_VIP} (OVN localnet VLAN)"
echo "  Apps DNS:    *.apps.${TENANT_NAME}.${BASE_DOMAIN} -> ${APPS_ELB:-${METALLB_VIP}}"
