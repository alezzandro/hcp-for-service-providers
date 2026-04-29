#!/usr/bin/env bash
# reset-demo.sh -- Remove everything created by scripts 08, 09, and 10.
#
# This deletes both tenant hosted clusters, their DNS records, the hub ANP,
# infra-side namespaces, and all generated tenant files. The hub cluster,
# infra cluster, operators, and secondary-network configuration (scripts
# 00-07) are left intact so you can re-run 08-10 immediately.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP_DIR="${DEMO_DIR}/setup"
ENV_FILE="${SETUP_DIR}/.generated-infra.env"
HUB_KUBECONFIG="${SETUP_DIR}/.generated-hub-kubeconfig"
VIRT_KUBECONFIG="${SETUP_DIR}/.generated-virt-kubeconfig"

[[ -f "${DEMO_DIR}/credentials.env" ]] && source "${DEMO_DIR}/credentials.env"
[[ -f "${ENV_FILE}" ]] && source "${ENV_FILE}"

echo "=== Resetting demo (removing resources from scripts 08, 09, 10) ==="
echo ""
echo "This will delete:"
echo "  - Hosted clusters: tenant-a, tenant-b"
echo "  - ManagedClusters (ACM auto-imported)"
echo "  - AdminNetworkPolicy on the hub"
echo "  - Route53 DNS records (api.tenant-*, *.apps.tenant-*)"
echo "  - Infra namespaces (clusters-tenant-a, clusters-tenant-b)"
echo "  - Generated tenant kubeconfigs and infra SA kubeconfigs"
echo ""
echo "The following are preserved:"
echo "  - Hub and infra OCP clusters"
echo "  - ACM, MCE, HyperShift, OCP Virt, NMState operators"
echo "  - Secondary NIC attachment, OVS bridge, and OVN localnet configuration"
echo ""
read -rp "Continue? [y/N] " confirm
if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
  echo "Aborted."
  exit 0
fi

# ─── Step 1: Delete AdminNetworkPolicy (script 10) ──────────────────
echo ""
echo "--- Step 1: Removing AdminNetworkPolicy from hub ---"
export KUBECONFIG="${HUB_KUBECONFIG}"
if oc get adminnetworkpolicy hcp-control-plane-isolation &>/dev/null; then
  oc delete adminnetworkpolicy hcp-control-plane-isolation
  echo "    ANP deleted."
else
  echo "    ANP not found. Skipping."
fi

# ─── Step 2: Delete hosted clusters (scripts 08, 09) ────────────────
echo ""
echo "--- Step 2: Deleting hosted clusters ---"
for tenant in tenant-a tenant-b; do
  if oc get hostedcluster "${tenant}" -n clusters &>/dev/null; then
    echo "    Deleting HostedCluster ${tenant}..."
    oc delete hostedcluster "${tenant}" -n clusters --wait=false
  else
    echo "    HostedCluster ${tenant} not found. Skipping."
  fi
done

# Wait for both deletions to complete
for tenant in tenant-a tenant-b; do
  if oc get hostedcluster "${tenant}" -n clusters &>/dev/null 2>&1; then
    echo "    Waiting for ${tenant} deletion..."
    for i in $(seq 1 60); do
      if ! oc get hostedcluster "${tenant}" -n clusters &>/dev/null 2>&1; then
        echo "    HostedCluster ${tenant} deleted."
        break
      fi
      if [[ "${i}" -eq 60 ]]; then
        echo "    WARNING: ${tenant} still exists after 15 minutes. Continuing anyway."
      fi
      sleep 15
    done
  fi
done

# ─── Step 3: Clean up ManagedClusters ───────────────────────────────
echo ""
echo "--- Step 3: Removing ManagedClusters ---"
for tenant in tenant-a tenant-b; do
  if oc get managedcluster "${tenant}" &>/dev/null 2>&1; then
    echo "    Deleting ManagedCluster ${tenant}..."
    oc delete managedcluster "${tenant}" --wait=false 2>/dev/null || true
  fi
done
# The import-controller finalizers can hang when the hosted cluster is already
# gone. Wait briefly, then force-remove any remaining finalizers.
sleep 10
for tenant in tenant-a tenant-b; do
  if oc get managedcluster "${tenant}" &>/dev/null 2>&1; then
    echo "    ManagedCluster ${tenant} stuck on finalizers. Force-removing..."
    oc patch managedcluster "${tenant}" --type=json \
      -p '[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
  fi
done

# ─── Step 4: Remove Route53 DNS records ──────────────────────────────
echo ""
echo "--- Step 4: Removing Route53 DNS records ---"
if [[ -n "${ROUTE53_ZONE_ID:-}" && -n "${BASE_DOMAIN:-}" ]]; then
  for tenant in tenant-a tenant-b; do
    for record_name in "\\052.apps.${tenant}.${BASE_DOMAIN}" "api.${tenant}.${BASE_DOMAIN}"; do
      EXISTING=$(aws route53 list-resource-record-sets --hosted-zone-id "${ROUTE53_ZONE_ID}" \
        --query "ResourceRecordSets[?Name=='${record_name}.']" --output json --region "${AWS_REGION}" 2>/dev/null || echo "[]")
      if [[ "${EXISTING}" != "[]" && "${EXISTING}" != "null" ]]; then
        REC_TYPE=$(echo "${EXISTING}" | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['Type'])" 2>/dev/null || true)
        REC_TTL=$(echo "${EXISTING}" | python3 -c "import json,sys; print(json.load(sys.stdin)[0].get('TTL',300))" 2>/dev/null || true)
        REC_VAL=$(echo "${EXISTING}" | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['ResourceRecords'][0]['Value'])" 2>/dev/null || true)
        if [[ -n "${REC_TYPE}" && -n "${REC_VAL}" ]]; then
          echo "    Deleting ${REC_TYPE} record: ${record_name}"
          aws route53 change-resource-record-sets \
            --hosted-zone-id "${ROUTE53_ZONE_ID}" \
            --change-batch "{
              \"Changes\": [{
                \"Action\": \"DELETE\",
                \"ResourceRecordSet\": {
                  \"Name\": \"${record_name}\",
                  \"Type\": \"${REC_TYPE}\",
                  \"TTL\": ${REC_TTL},
                  \"ResourceRecords\": [{\"Value\": \"${REC_VAL}\"}]
                }
              }]
            }" --region "${AWS_REGION}" 2>/dev/null || true
        fi
      fi
    done
  done
else
  echo "    ROUTE53_ZONE_ID or BASE_DOMAIN not set. Skipping DNS cleanup."
fi

# ─── Step 5: Clean up infra cluster namespaces ───────────────────────
echo ""
echo "--- Step 5: Cleaning up infra cluster namespaces ---"
if [[ -f "${VIRT_KUBECONFIG}" ]]; then
  export KUBECONFIG="${VIRT_KUBECONFIG}"
  for tenant in tenant-a tenant-b; do
    ns="clusters-${tenant}"
    if oc get namespace "${ns}" &>/dev/null 2>&1; then
      echo "    Deleting namespace ${ns}..."
      oc delete namespace "${ns}" --wait=false 2>/dev/null || true
    else
      echo "    Namespace ${ns} not found. Skipping."
    fi
  done
else
  echo "    Virt kubeconfig not found. Skipping infra namespace cleanup."
fi

# ─── Step 6: Remove generated files ─────────────────────────────────
echo ""
echo "--- Step 6: Cleaning up generated tenant files ---"
rm -f "${SETUP_DIR}/.generated-tenant-a-kubeconfig"
rm -f "${SETUP_DIR}/.generated-tenant-b-kubeconfig"
rm -f "${SETUP_DIR}/.generated-infra-sa-kubeconfig"
rm -f "${SETUP_DIR}/.generated-infra-sa-kubeconfig-b"
echo "    Removed tenant kubeconfigs and infra SA kubeconfigs."

echo ""
echo "============================================="
echo "  Reset complete."
echo ""
echo "  Preserved:"
echo "    - Hub cluster (OCP ${HUB_KUBECONFIG})"
echo "    - Infra cluster (OCP ${VIRT_KUBECONFIG})"
echo "    - ACM, MCE, HyperShift, OCP Virt, NMState"
echo "    - OVS bridge (br-secondary) and OVN localnet NADs"
echo ""
echo "  To re-provision tenants, run:"
echo "    ./setup/08-provision-tenant-a.sh"
echo "    ./setup/09-provision-tenant-b.sh"
echo "    ./setup/10-apply-security-policies.sh"
echo "============================================="
