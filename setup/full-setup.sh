#!/usr/bin/env bash
# full-setup.sh -- Run all setup scripts in order.
set -euo pipefail

SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SCRIPTS=(
  "00-prereqs.sh"
  "01-provision-infrastructure.sh"
  "02-install-hub-cluster.sh"
  "03-install-virt-cluster.sh"
  "04-attach-secondary-nic.sh"
  "05-install-acm-mce.sh"
  "06-install-ocpvirt-nmstate.sh"
  "06b-install-efs-csi.sh"
  "07-configure-secondary-network.sh"
  "08-provision-tenant-a.sh"
  "09-provision-tenant-b.sh"
  "10-apply-security-policies.sh"
)

TOTAL=${#SCRIPTS[@]}
CURRENT=0

for script in "${SCRIPTS[@]}"; do
  ((CURRENT++))
  echo ""
  echo "================================================================"
  echo "  [${CURRENT}/${TOTAL}] Running ${script}"
  echo "================================================================"
  echo ""

  bash "${SETUP_DIR}/${script}"

  echo ""
  echo "  [${CURRENT}/${TOTAL}] ${script} completed successfully."
done

echo ""
echo "================================================================"
echo "  Full setup complete!"
echo "================================================================"
echo ""
echo "Run './setup/show-credentials.sh' to see all URLs and kubeconfigs."
echo "Run './setup/health-check.sh' to verify all components."
