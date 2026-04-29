#!/usr/bin/env bash
# 10-apply-security-policies.sh -- Apply ANP on hub, EgressFirewall in tenant clusters.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP_DIR="${DEMO_DIR}/setup"
HUB_KUBECONFIG="${SETUP_DIR}/.generated-hub-kubeconfig"
TENANT_A_KUBECONFIG="${SETUP_DIR}/.generated-tenant-a-kubeconfig"
TENANT_B_KUBECONFIG="${SETUP_DIR}/.generated-tenant-b-kubeconfig"

echo "=== Applying security policies ==="

# --- AdminNetworkPolicy on hub ---
echo "--- Applying AdminNetworkPolicy on hub cluster ---"
export KUBECONFIG="${HUB_KUBECONFIG}"

# Discover the hub cluster's service CIDR and API IP for the ANP template
HUB_SVC_CIDR=$(oc get network.config cluster -o jsonpath='{.status.serviceNetwork[0]}')
HUB_API_IP=$(oc get endpointslice kubernetes -n default -o jsonpath='{.endpoints[0].addresses[0]}' 2>/dev/null || \
  oc get endpoints kubernetes -n default -o jsonpath='{.subsets[0].addresses[0].ip}')

echo "    Hub service CIDR: ${HUB_SVC_CIDR}"
echo "    Hub API server:   ${HUB_API_IP}"

sed -e "s|172.30.0.0/16|${HUB_SVC_CIDR}|g" \
    -e "s|10.0.0.1/32|${HUB_API_IP}/32|g" \
    "${DEMO_DIR}/manifests/hub/admin-network-policy.yaml" | oc apply -f -

echo "    AdminNetworkPolicy applied."

# --- EgressFirewall in tenant clusters ---
for tenant in a b; do
  TENANT_KC="${SETUP_DIR}/.generated-tenant-${tenant}-kubeconfig"
  if [[ ! -f "${TENANT_KC}" ]]; then
    echo "    WARNING: Tenant ${tenant} kubeconfig not found. Skipping EgressFirewall."
    continue
  fi

  echo "--- Applying EgressFirewall in Tenant ${tenant} ---"
  export KUBECONFIG="${TENANT_KC}"

  # Create a test namespace and apply the EgressFirewall
  oc create namespace customer-workloads --dry-run=client -o yaml | oc apply -f -
  oc apply -f "${DEMO_DIR}/manifests/tenant-${tenant}/egress-firewall.yaml"
  echo "    EgressFirewall applied in Tenant ${tenant}."
done

echo ""
echo "Security policies applied:"
echo "  - AdminNetworkPolicy on hub (hcp-control-plane-isolation)"
echo "  - EgressFirewall in Tenant A and B (customer-workloads namespace)"
