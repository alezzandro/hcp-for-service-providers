#!/usr/bin/env bash
# trigger.sh -- Live-migrate a tenant-a worker VM to a different node.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP_DIR="${DEMO_DIR}/setup"
VIRT_KUBECONFIG="${SETUP_DIR}/.generated-virt-kubeconfig"

export KUBECONFIG="${VIRT_KUBECONFIG}"

NAMESPACE="clusters-tenant-a"

VMI=$(oc get vmi -n "${NAMESPACE}" -o jsonpath='{.items[0].metadata.name}')
SRC_NODE=$(oc get vmi "${VMI}" -n "${NAMESPACE}" -o jsonpath='{.status.nodeName}')

echo "=== Live Migration Demo ==="
echo ""
echo "  VMI:          ${VMI}"
echo "  Namespace:    ${NAMESPACE}"
echo "  Source node:   ${SRC_NODE}"
echo ""

echo "--- Triggering live migration ---"
virtctl migrate "${VMI}" -n "${NAMESPACE}"

echo ""
echo "--- Watching migration progress ---"
echo "    (press Ctrl+C to stop watching; migration continues in background)"
echo ""
oc get vmim -n "${NAMESPACE}" -w
