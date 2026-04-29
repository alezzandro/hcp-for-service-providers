#!/usr/bin/env bash
# 06b-install-efs-csi.sh -- Install AWS EFS CSI Driver and StorageClass on the infra cluster.
# Skips entirely when ENABLE_EFS_LIVE_MIGRATION is not "true".
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP_DIR="${DEMO_DIR}/setup"
ENV_FILE="${SETUP_DIR}/.generated-infra.env"
VIRT_KUBECONFIG="${SETUP_DIR}/.generated-virt-kubeconfig"

source "${DEMO_DIR}/credentials.env"
[[ -f "${ENV_FILE}" ]] && source "${ENV_FILE}"

if [[ "${ENABLE_EFS_LIVE_MIGRATION:-false}" != "true" ]]; then
  echo "=== EFS live-migration mode is disabled. Skipping EFS CSI installation. ==="
  exit 0
fi

if [[ -z "${EFS_FILESYSTEM_ID:-}" ]]; then
  echo "ERROR: ENABLE_EFS_LIVE_MIGRATION is true but EFS_FILESYSTEM_ID is not set."
  echo "       Run 01-provision-infrastructure.sh first with enable_efs=true."
  exit 1
fi

echo "=== Installing AWS EFS CSI Driver on infra cluster ==="
export KUBECONFIG="${VIRT_KUBECONFIG}"

echo "--- Creating Namespace and OperatorGroup ---"
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-cluster-csi-drivers
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-cluster-csi-drivers
  namespace: openshift-cluster-csi-drivers
spec: {}
EOF

echo "--- Creating Subscription for AWS EFS CSI Driver Operator ---"
cat <<'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: aws-efs-csi-driver-operator
  namespace: openshift-cluster-csi-drivers
spec:
  channel: stable
  installPlanApproval: Automatic
  name: aws-efs-csi-driver-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "--- Waiting for EFS CSI Driver Operator CSV ---"
for i in $(seq 1 30); do
  CSV=$(oc get csv -n openshift-cluster-csi-drivers -o name 2>/dev/null | grep aws-efs || true)
  if [[ -n "${CSV}" ]]; then
    PHASE=$(oc get "${CSV}" -n openshift-cluster-csi-drivers -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "${PHASE}" == "Succeeded" ]]; then
      echo "    EFS CSI Driver Operator is Succeeded."
      break
    fi
  fi
  echo "    Waiting for operator... (${i}/30)"
  sleep 20
done

echo "--- Creating ClusterCSIDriver for EFS ---"
cat <<'EOF' | oc apply -f -
apiVersion: operator.openshift.io/v1
kind: ClusterCSIDriver
metadata:
  name: efs.csi.aws.com
spec:
  managementState: Managed
EOF

echo "--- Waiting for EFS CSI driver pods ---"
for i in $(seq 1 30); do
  READY=$(oc get ds aws-efs-csi-driver-node -n openshift-cluster-csi-drivers \
    -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
  DESIRED=$(oc get ds aws-efs-csi-driver-node -n openshift-cluster-csi-drivers \
    -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
  if [[ "${READY}" -gt 0 && "${READY}" == "${DESIRED}" ]]; then
    echo "    EFS CSI driver DaemonSet ready: ${READY}/${DESIRED}"
    break
  fi
  echo "    Waiting for CSI driver pods... ${READY}/${DESIRED} (${i}/30)"
  sleep 20
done

echo "--- Creating StorageClass efs-sc ---"
cat <<EOF | oc apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: "${EFS_FILESYSTEM_ID}"
  directoryPerms: "777"
  basePath: "/kubevirt"
  uid: "0"
  gid: "0"
volumeBindingMode: Immediate
reclaimPolicy: Delete
EOF

echo ""
echo "EFS CSI Driver installed."
echo "  StorageClass: efs-sc"
echo "  EFS ID:       ${EFS_FILESYSTEM_ID}"
echo "  Provisioner:  efs.csi.aws.com (dynamic via access points)"
