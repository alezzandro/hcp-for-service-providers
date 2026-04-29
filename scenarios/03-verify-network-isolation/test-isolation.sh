#!/usr/bin/env bash
# test-isolation.sh -- Verify L2 network isolation between tenants.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP_DIR="${DEMO_DIR}/setup"
TENANT_A_KC="${SETUP_DIR}/.generated-tenant-a-kubeconfig"
TENANT_B_KC="${SETUP_DIR}/.generated-tenant-b-kubeconfig"

PASS=0
FAIL=0

result() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    echo "  [PASS] ${desc}"
    ((PASS++))
  else
    echo "  [FAIL] ${desc} (expected: ${expected}, got: ${actual})"
    ((FAIL++))
  fi
}

echo "=== Network Isolation Test ==="
echo ""

# Deploy test pod in Tenant A
echo "--- Setting up test pod in Tenant A ---"
export KUBECONFIG="${TENANT_A_KC}"
oc run test-isolation --image=registry.access.redhat.com/ubi9/ubi-minimal \
  --restart=Never --overrides='{"spec":{"terminationGracePeriodSeconds":0}}' \
  -- sleep 3600 2>/dev/null || true
oc wait pod/test-isolation --for=condition=Ready --timeout=120s

# Get Tenant A node IP
TENANT_A_NODE=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "  Tenant A node IP: ${TENANT_A_NODE}"

# Get Tenant B node IP
export KUBECONFIG="${TENANT_B_KC}"
TENANT_B_NODE=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "  Tenant B node IP: ${TENANT_B_NODE}"

# Test 1: Intra-tenant connectivity (should succeed)
echo ""
echo "--- Test 1: Intra-tenant connectivity (Tenant A -> Tenant A) ---"
export KUBECONFIG="${TENANT_A_KC}"
if oc exec test-isolation -- ping -c 2 -W 5 "${TENANT_A_NODE}" &>/dev/null; then
  result "Tenant A pod -> Tenant A node" "reachable" "reachable"
else
  result "Tenant A pod -> Tenant A node" "reachable" "unreachable"
fi

# Test 2: Cross-tenant connectivity (should fail)
echo ""
echo "--- Test 2: Cross-tenant connectivity (Tenant A -> Tenant B) ---"
if oc exec test-isolation -- ping -c 2 -W 5 "${TENANT_B_NODE}" &>/dev/null; then
  result "Tenant A pod -> Tenant B node" "blocked" "reachable"
else
  result "Tenant A pod -> Tenant B node" "blocked" "blocked"
fi

# Cleanup
echo ""
echo "--- Cleanup ---"
export KUBECONFIG="${TENANT_A_KC}"
oc delete pod test-isolation --ignore-not-found --wait=false

echo ""
echo "=== Results ==="
echo "  Passed: ${PASS}   Failed: ${FAIL}"
[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
