#!/usr/bin/env bash
# 06-install-ocpvirt-nmstate.sh -- Install OCP Virtualization and NMState on the infra cluster.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP_DIR="${DEMO_DIR}/setup"
VIRT_KUBECONFIG="${SETUP_DIR}/.generated-virt-kubeconfig"

export KUBECONFIG="${VIRT_KUBECONFIG}"

echo "=== Installing OCP Virtualization + NMState on Infra cluster ==="

# --- OCP Virtualization ---
echo "--- Applying OCP Virt operator subscription ---"
oc apply -f "${DEMO_DIR}/manifests/virt/ocpvirt-subscription.yaml"

echo "--- Waiting for OCP Virt operator ---"
for i in $(seq 1 60); do
  CSV=$(oc get csv -n openshift-cnv -o name 2>/dev/null | grep kubevirt-hyperconverged-operator || true)
  if [[ -n "${CSV}" ]]; then
    PHASE=$(oc get "${CSV}" -n openshift-cnv -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "${PHASE}" == "Succeeded" ]]; then
      echo "    OCP Virt operator CSV is Succeeded."
      break
    fi
  fi
  echo "    Waiting... (${i}/60)"
  sleep 30
done

echo "--- Creating HyperConverged instance ---"
oc apply -f "${DEMO_DIR}/manifests/virt/hyperconverged.yaml"

echo "--- Waiting for HyperConverged to be Available ---"
for i in $(seq 1 60); do
  AVAIL=$(oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "Unknown")
  if [[ "${AVAIL}" == "True" ]]; then
    echo "    HyperConverged is Available."
    break
  fi
  echo "    Status: Available=${AVAIL} (${i}/60)"
  sleep 30
done

# --- NMState ---
echo "--- Applying NMState operator subscription ---"
oc apply -f "${DEMO_DIR}/manifests/virt/nmstate-subscription.yaml"

echo "--- Waiting for NMState operator ---"
for i in $(seq 1 30); do
  CSV=$(oc get csv -n openshift-nmstate -o name 2>/dev/null | grep kubernetes-nmstate-operator || true)
  if [[ -n "${CSV}" ]]; then
    PHASE=$(oc get "${CSV}" -n openshift-nmstate -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "${PHASE}" == "Succeeded" ]]; then
      echo "    NMState operator CSV is Succeeded."
      break
    fi
  fi
  echo "    Waiting... (${i}/30)"
  sleep 20
done

echo "--- Creating NMState instance ---"
oc apply -f "${DEMO_DIR}/manifests/virt/nmstate-instance.yaml"

echo "--- Waiting for NMState to be Available ---"
for i in $(seq 1 20); do
  AVAIL=$(oc get nmstate nmstate -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "Unknown")
  if [[ "${AVAIL}" == "True" ]]; then
    echo "    NMState is Available."
    break
  fi
  echo "    Waiting... (${i}/20)"
  sleep 15
done

echo ""
echo "OCP Virtualization and NMState installed on the infra cluster."
