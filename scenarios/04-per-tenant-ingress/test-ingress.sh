#!/usr/bin/env bash
# test-ingress.sh -- Verify per-tenant ingress is working.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP_DIR="${DEMO_DIR}/setup"

echo "=== Per-Tenant Ingress Test ==="
echo ""

for tenant in tenant-a tenant-b; do
  TENANT_KC="${SETUP_DIR}/.generated-${tenant}-kubeconfig"
  if [[ ! -f "${TENANT_KC}" ]]; then
    echo "  [SKIP] ${tenant} kubeconfig not found"
    continue
  fi

  export KUBECONFIG="${TENANT_KC}"
  echo "--- ${tenant} ---"

  VIP=$(oc get svc metallb-ingress -n openshift-ingress \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "none")
  echo "  MetalLB VIP: ${VIP}"

  POOL=$(oc get ipaddresspool -n metallb-system -o jsonpath='{.items[0].spec.addresses[0]}' 2>/dev/null || echo "none")
  echo "  IP Pool:     ${POOL}"

  ROUTE_HOST=$(oc get route hello-openshift -n demo-app \
    -o jsonpath='{.spec.host}' 2>/dev/null || echo "none")
  if [[ "${ROUTE_HOST}" != "none" ]]; then
    echo "  Route:       ${ROUTE_HOST}"
    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://${ROUTE_HOST}/" 2>/dev/null || echo "000")
    echo "  HTTP Status: ${HTTP_CODE}"
  else
    echo "  Route:       not deployed (run sample-workload.yaml first)"
  fi
  echo ""
done
