#!/usr/bin/env bash
# provision.sh -- Provision Tenant C (demo scenario).
# This is a simplified version for live demo. For production, use the full
# setup scripts as a template.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "=== Scenario: Provision Tenant C ==="
echo ""
echo "This scenario creates a third tenant to demonstrate the repeatable"
echo "provisioning process. See the README.md for step-by-step walkthrough."
echo ""
echo "For a live demo, follow the manual steps in README.md to explain"
echo "each component as you create it."
echo ""
echo "To run the automated setup instead:"
echo "  Follow the same pattern as setup/08-provision-tenant-a.sh"
echo "  with VLAN 302, CIDR 10.140.0.0/14, VIP 10.100.32.100"
