#!/usr/bin/env bash
# hcp-create.sh -- Create Tenant A hosted cluster with external infrastructure.
#
# This is the standalone version of the hcp create command.
# The setup script 08-provision-tenant-a.sh wraps this with additional
# automation (RBAC, kubeconfig generation, MetalLB, DNS).
set -euo pipefail

TENANT_NAME="tenant-a"
INFRA_NAMESPACE="clusters-${TENANT_NAME}"
CLUSTER_CIDR="10.132.0.0/14"
SERVICE_CIDR="172.31.0.0/16"
RELEASE_IMAGE="quay.io/openshift-release-dev/ocp-release:4.19.0-multi"
BASE_DOMAIN="${BASE_DOMAIN:?Set BASE_DOMAIN}"
PULL_SECRET="${PULL_SECRET_FILE:?Set PULL_SECRET_FILE}"
SSH_KEY="${SSH_KEY_FILE:?Set SSH_KEY_FILE}"
INFRA_KUBECONFIG="${INFRA_KUBECONFIG_FILE:?Set INFRA_KUBECONFIG_FILE}"

hcp create cluster kubevirt \
  --name "${TENANT_NAME}" \
  --namespace clusters \
  --node-pool-replicas 2 \
  --node-upgrade-type InPlace \
  --pull-secret "${PULL_SECRET}" \
  --ssh-key "${SSH_KEY}" \
  --memory "16Gi" \
  --cores 4 \
  --root-volume-size 60 \
  --release-image "${RELEASE_IMAGE}" \
  --etcd-storage-class gp3-csi \
  --cluster-cidr "${CLUSTER_CIDR}" \
  --service-cidr "${SERVICE_CIDR}" \
  --additional-network "name:${INFRA_NAMESPACE}/nad-vlan300" \
  --infra-kubeconfig-file "${INFRA_KUBECONFIG}" \
  --infra-namespace "${INFRA_NAMESPACE}" \
  --base-domain "${BASE_DOMAIN}" \
  --kas-dns-name "api.${TENANT_NAME}.${BASE_DOMAIN}"

echo "Hosted cluster '${TENANT_NAME}' creation initiated."
echo ""
echo "Monitor: oc get hostedcluster ${TENANT_NAME} -n clusters -w"
