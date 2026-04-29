#!/usr/bin/env bash
# health-check.sh -- Verify all demo components are healthy.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP_DIR="${DEMO_DIR}/setup"
HUB_KUBECONFIG="${SETUP_DIR}/.generated-hub-kubeconfig"
VIRT_KUBECONFIG="${SETUP_DIR}/.generated-virt-kubeconfig"
TENANT_A_KUBECONFIG="${SETUP_DIR}/.generated-tenant-a-kubeconfig"
TENANT_B_KUBECONFIG="${SETUP_DIR}/.generated-tenant-b-kubeconfig"

PASS=0
FAIL=0

check() {
  local desc="$1"
  shift
  if "$@" &>/dev/null; then
    echo "  [OK]   ${desc}"
    ((PASS++))
  else
    echo "  [FAIL] ${desc}"
    ((FAIL++))
  fi
}

echo "=== Hub Cluster ==="
export KUBECONFIG="${HUB_KUBECONFIG}"

check "Hub cluster reachable" oc cluster-info
check "ACM MultiClusterHub Running" bash -c \
  '[[ "$(oc get multiclusterhub multiclusterhub -n open-cluster-management -o jsonpath={.status.phase} 2>/dev/null)" == "Running" ]]'
check "HyperShift operator available" bash -c \
  '[[ "$(oc get deployment operator -n hypershift -o jsonpath={.status.availableReplicas} 2>/dev/null)" -ge 1 ]]'

for tenant in tenant-a tenant-b; do
  check "HostedCluster ${tenant} available" bash -c \
    '[[ "$(oc get hostedcluster '"${tenant}"' -n clusters -o jsonpath={.status.conditions[?(@.type==\"Available\")].status} 2>/dev/null)" == "True" ]]'
done

check "AdminNetworkPolicy exists" oc get adminnetworkpolicy hcp-control-plane-isolation

echo ""
echo "=== Infrastructure Cluster ==="
export KUBECONFIG="${VIRT_KUBECONFIG}"

check "Infra cluster reachable" oc cluster-info
check "OCP Virt HyperConverged available" bash -c \
  '[[ "$(oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv -o jsonpath={.status.conditions[?(@.type==\"Available\")].status} 2>/dev/null)" == "True" ]]'
check "NMState available" bash -c \
  '[[ "$(oc get nmstate nmstate -o jsonpath={.status.conditions[?(@.type==\"Available\")].status} 2>/dev/null)" == "True" ]]'

for nncp in $(oc get nncp -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  check "NNCP ${nncp} available" bash -c \
    '[[ "$(oc get nncp '"${nncp}"' -o jsonpath={.status.conditions[?(@.type==\"Available\")].reason} 2>/dev/null)" == "SuccessfullyConfigured" ]]'
done

RUNNING_VMS=$(oc get vmi -A --no-headers 2>/dev/null | wc -l)
check "KubeVirt VMs running (expected 4)" bash -c "[[ ${RUNNING_VMS} -ge 4 ]]"

echo ""
echo "=== Tenant A ==="
if [[ -f "${TENANT_A_KUBECONFIG}" ]]; then
  export KUBECONFIG="${TENANT_A_KUBECONFIG}"
  check "Tenant A cluster reachable" oc cluster-info
  check "Tenant A nodes Ready" bash -c \
    '[[ $(oc get nodes --no-headers 2>/dev/null | grep -c " Ready") -ge 2 ]]'
  check "Tenant A MetalLB operator" bash -c \
    'oc get csv -n metallb-system 2>/dev/null | grep -q Succeeded'
else
  echo "  [SKIP] Tenant A kubeconfig not found"
fi

echo ""
echo "=== Tenant B ==="
if [[ -f "${TENANT_B_KUBECONFIG}" ]]; then
  export KUBECONFIG="${TENANT_B_KUBECONFIG}"
  check "Tenant B cluster reachable" oc cluster-info
  check "Tenant B nodes Ready" bash -c \
    '[[ $(oc get nodes --no-headers 2>/dev/null | grep -c " Ready") -ge 2 ]]'
  check "Tenant B MetalLB operator" bash -c \
    'oc get csv -n metallb-system 2>/dev/null | grep -q Succeeded'
else
  echo "  [SKIP] Tenant B kubeconfig not found"
fi

echo ""
echo "=== Summary ==="
echo "  Passed: ${PASS}   Failed: ${FAIL}"
if [[ ${FAIL} -gt 0 ]]; then
  echo "  Some checks failed. Review the output above."
  exit 1
fi
echo "  All checks passed."
exit 0
