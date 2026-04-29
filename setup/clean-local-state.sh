#!/usr/bin/env bash
# clean-local-state.sh -- Remove all locally generated state and artifacts.
#
# Use this when you have already deleted AWS resources manually (e.g. via the
# console or by letting the sandbox expire) and want to reset the local repo
# to a clean state, ready for a fresh run.
#
# Preserved: credentials.env, pull-secret.json, id_rsa.pub
# Deleted:   Terraform state/lock/.terraform, install-config dirs, kubeconfigs,
#            generated env files, terraform.tfvars
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP_DIR="${DEMO_DIR}/setup"
TF_DIR="${DEMO_DIR}/terraform"

echo "=== Cleaning local state files ==="
echo ""
echo "This will remove all generated/state files but keep:"
echo "  - credentials.env"
echo "  - pull-secret.json"
echo "  - id_rsa.pub"
echo ""

# --- Terraform ---
echo "--- Terraform state ---"
for f in "${TF_DIR}/terraform.tfstate" \
         "${TF_DIR}/terraform.tfstate.backup" \
         "${TF_DIR}/terraform.tfvars" \
         "${TF_DIR}/.terraform.lock.hcl"; do
  if [[ -f "${f}" ]]; then
    rm -f "${f}"
    echo "  Removed ${f##*/}"
  fi
done
if [[ -d "${TF_DIR}/.terraform" ]]; then
  rm -rf "${TF_DIR}/.terraform"
  echo "  Removed .terraform/"
fi
# Remove any leftover plan files
rm -f "${TF_DIR}"/tfplan "${TF_DIR}"/*.tfplan

# --- OCP install directories ---
echo "--- OCP install artifacts ---"
for cluster in hub virt; do
  dir="${DEMO_DIR}/install-configs/${cluster}"
  if [[ -d "${dir}" ]]; then
    rm -rf "${dir}"
    echo "  Removed install-configs/${cluster}/"
  fi
done

# --- Generated env files and kubeconfigs ---
echo "--- Generated configs ---"
count=0
for f in "${SETUP_DIR}"/.generated-*; do
  [[ -e "${f}" ]] || continue
  rm -f "${f}"
  echo "  Removed ${f##*/}"
  count=$((count + 1))
done
[[ ${count} -eq 0 ]] && echo "  (none found)"

# --- Stale log files ---
echo "--- Log files ---"
count=0
for f in "${DEMO_DIR}"/*.log "${DEMO_DIR}"/setup/*.log; do
  [[ -e "${f}" ]] || continue
  rm -f "${f}"
  echo "  Removed ${f##*/}"
  count=$((count + 1))
done
[[ ${count} -eq 0 ]] && echo "  (none found)"

echo ""
echo "Local state cleaned. You can now run a fresh setup with:"
echo "  ./setup/full-setup.sh"
