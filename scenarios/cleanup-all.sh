#!/usr/bin/env bash
# cleanup-all.sh -- Clean up artifacts from all demo scenarios.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP_DIR="${DEMO_DIR}/setup"

echo "=== Cleaning up all scenario artifacts ==="

# Scenario 02: Tenant C
if [[ -x "${DEMO_DIR}/scenarios/02-provision-new-tenant/cleanup.sh" ]]; then
  bash "${DEMO_DIR}/scenarios/02-provision-new-tenant/cleanup.sh" || true
fi

# Scenario 03 & 04: Test pods and sample workloads
for tenant in tenant-a tenant-b; do
  TENANT_KC="${SETUP_DIR}/.generated-${tenant}-kubeconfig"
  [[ -f "${TENANT_KC}" ]] || continue
  export KUBECONFIG="${TENANT_KC}"

  echo "--- Cleaning up in ${tenant} ---"
  oc delete pod test-isolation test-ping egress-test --ignore-not-found 2>/dev/null || true
  oc delete namespace demo-app --ignore-not-found 2>/dev/null || true
  oc delete pod egress-test -n customer-workloads --ignore-not-found 2>/dev/null || true
done

echo ""
echo "All scenario artifacts cleaned up."
