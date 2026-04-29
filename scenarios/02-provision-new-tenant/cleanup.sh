#!/usr/bin/env bash
# cleanup.sh -- Remove Tenant C resources created by this scenario.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP_DIR="${DEMO_DIR}/setup"
HUB_KUBECONFIG="${SETUP_DIR}/.generated-hub-kubeconfig"
VIRT_KUBECONFIG="${SETUP_DIR}/.generated-virt-kubeconfig"

echo "=== Cleaning up Tenant C ==="

if [[ -f "${HUB_KUBECONFIG}" ]]; then
  export KUBECONFIG="${HUB_KUBECONFIG}"
  if oc get hostedcluster tenant-c -n clusters &>/dev/null; then
    echo "--- Deleting hosted cluster tenant-c ---"
    oc delete hostedcluster tenant-c -n clusters --wait=true --timeout=10m || true
  fi
fi

if [[ -f "${VIRT_KUBECONFIG}" ]]; then
  export KUBECONFIG="${VIRT_KUBECONFIG}"
  oc delete namespace clusters-tenant-c 2>/dev/null || true
fi

echo "Tenant C cleanup complete."
