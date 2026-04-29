#!/usr/bin/env bash
# 05-install-acm-mce.sh -- Install ACM, MCE, and enable HyperShift on the hub.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP_DIR="${DEMO_DIR}/setup"
HUB_KUBECONFIG="${SETUP_DIR}/.generated-hub-kubeconfig"

export KUBECONFIG="${HUB_KUBECONFIG}"

echo "=== Installing ACM + MCE on Hub cluster ==="

# Check if ACM is already installed
if oc get multiclusterhub multiclusterhub -n open-cluster-management &>/dev/null; then
  echo "MultiClusterHub already exists. Checking status..."
  STATUS=$(oc get multiclusterhub multiclusterhub -n open-cluster-management -o jsonpath='{.status.phase}')
  echo "  Status: ${STATUS}"
  if [[ "${STATUS}" == "Running" ]]; then
    echo "ACM is already installed and running. Skipping."
    exit 0
  fi
fi

echo "--- Applying ACM operator subscription ---"
oc apply -f "${DEMO_DIR}/manifests/hub/acm-subscription.yaml"

echo "--- Waiting for ACM operator to be ready ---"
echo "    (this may take several minutes)"
for i in $(seq 1 60); do
  CSV=$(oc get csv -n open-cluster-management -o name 2>/dev/null | grep advanced-cluster-management || true)
  if [[ -n "${CSV}" ]]; then
    PHASE=$(oc get "${CSV}" -n open-cluster-management -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "${PHASE}" == "Succeeded" ]]; then
      echo "    ACM operator CSV is Succeeded."
      break
    fi
  fi
  echo "    Waiting... (${i}/60)"
  sleep 30
done

echo "--- Creating MultiClusterHub ---"
oc apply -f "${DEMO_DIR}/manifests/hub/multiclusterhub.yaml"

echo "--- Waiting for MultiClusterHub to be Running ---"
echo "    (this may take 10-15 minutes)"
for i in $(seq 1 60); do
  STATUS=$(oc get multiclusterhub multiclusterhub -n open-cluster-management -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
  if [[ "${STATUS}" == "Running" ]]; then
    echo "    MultiClusterHub is Running."
    break
  fi
  echo "    Status: ${STATUS} (${i}/60)"
  sleep 30
done

echo "--- Enabling HyperShift (managed by MCE) ---"
oc patch mce multiclusterengine --type=merge -p '{"spec":{"overrides":{"components":[{"name":"hypershift","enabled":true},{"name":"hypershift-local-hosting","enabled":true}]}}}'

echo "--- Waiting for HyperShift operator ---"
for i in $(seq 1 30); do
  READY=$(oc get deployment operator -n hypershift --no-headers 2>/dev/null | awk '{print $4}' || echo "0")
  if [[ "${READY}" -ge 1 ]]; then
    echo "    HyperShift operator is ready."
    break
  fi
  echo "    Waiting for HyperShift operator... (${i}/30)"
  sleep 20
done

echo ""
echo "ACM + MCE + HyperShift installed on the hub cluster."
