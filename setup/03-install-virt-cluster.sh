#!/usr/bin/env bash
# 03-install-virt-cluster.sh -- Install the bare-metal OCP Virt cluster via IPI.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP_DIR="${DEMO_DIR}/setup"
ENV_FILE="${SETUP_DIR}/.generated-infra.env"
INSTALL_DIR="${DEMO_DIR}/install-configs/virt"
KUBECONFIG_OUT="${SETUP_DIR}/.generated-virt-kubeconfig"

source "${DEMO_DIR}/credentials.env"
source "${ENV_FILE}"

CLUSTER_NAME="virt"

echo "=== Installing Infrastructure (OCP Virt) cluster ==="

if [[ -f "${KUBECONFIG_OUT}" ]]; then
  echo "Virt kubeconfig already exists at ${KUBECONFIG_OUT}."
  echo "If you need to reinstall, delete it and the install directory first."
  exit 0
fi

mkdir -p "${INSTALL_DIR}"

PRIVATE_SUBNETS=""
IFS=',' read -ra PSUBS <<< "${PRIVATE_SUBNET_IDS}"
for sid in "${PSUBS[@]}"; do
  PRIVATE_SUBNETS="${PRIVATE_SUBNETS}    - ${sid}"$'\n'
done

PUBLIC_SUBNETS=""
IFS=',' read -ra PUBSUBS <<< "${PUBLIC_SUBNET_IDS}"
for sid in "${PUBSUBS[@]}"; do
  PUBLIC_SUBNETS="${PUBLIC_SUBNETS}    - ${sid}"$'\n'
done

export CLUSTER_NAME BASE_DOMAIN AWS_REGION
export PRIVATE_SUBNETS PUBLIC_SUBNETS
export PULL_SECRET
PULL_SECRET=$(cat "${DEMO_DIR}/pull-secret.json")
export SSH_KEY
SSH_KEY=$(cat "${DEMO_DIR}/id_rsa.pub")

envsubst < "${DEMO_DIR}/install-configs/virt-install-config.yaml.tpl" > "${INSTALL_DIR}/install-config.yaml"

cp "${INSTALL_DIR}/install-config.yaml" "${INSTALL_DIR}/install-config.yaml.bak"

echo "--- Running openshift-install create cluster (m5.metal — this takes ~45 min) ---"
openshift-install create cluster --dir="${INSTALL_DIR}" --log-level=info

cp "${INSTALL_DIR}/auth/kubeconfig" "${KUBECONFIG_OUT}"

echo ""
echo "Infrastructure cluster installed."
echo "  Kubeconfig: ${KUBECONFIG_OUT}"
echo "  Console:    https://console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
