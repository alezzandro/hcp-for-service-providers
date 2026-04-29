#!/usr/bin/env bash
# cleanup.sh -- Remove completed VirtualMachineInstanceMigration objects.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP_DIR="${DEMO_DIR}/setup"
VIRT_KUBECONFIG="${SETUP_DIR}/.generated-virt-kubeconfig"

export KUBECONFIG="${VIRT_KUBECONFIG}"

echo "--- Cleaning up completed migrations ---"
for ns in clusters-tenant-a clusters-tenant-b; do
  VMIMS=$(oc get vmim -n "${ns}" -o name 2>/dev/null || true)
  if [[ -n "${VMIMS}" ]]; then
    echo "    Deleting migrations in ${ns}..."
    oc delete vmim --all -n "${ns}"
  else
    echo "    No migrations in ${ns}."
  fi
done
echo "Done."
