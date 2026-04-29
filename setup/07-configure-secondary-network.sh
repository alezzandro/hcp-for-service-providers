#!/usr/bin/env bash
# 07-configure-secondary-network.sh -- Configure OVN localnet on secondary NIC.
#
# Creates an OVS bridge (br-secondary) on the secondary NIC via NMState,
# declares an OVN bridge-mapping (tenant-physnet), and applies per-tenant
# OVN localnet NADs with VLAN tagging.  This approach makes tenant VMs
# live-migratable because OVN manages L2 forwarding at the SDN level.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP_DIR="${DEMO_DIR}/setup"
VIRT_KUBECONFIG="${SETUP_DIR}/.generated-virt-kubeconfig"

export KUBECONFIG="${VIRT_KUBECONFIG}"

echo "=== Configuring secondary network on infra cluster (OVN localnet) ==="

# --- Detect the secondary NIC name ---
echo "--- Detecting secondary NIC name on bare-metal nodes ---"
FIRST_NODE=$(oc get nodes -o jsonpath='{.items[0].metadata.name}')
echo "    Probing node: ${FIRST_NODE}"

# The secondary ENI name varies by instance type (ens1 on m5.metal, ens6 on m5.xlarge, etc.).
# Strategy: find physical NICs that are UP, not enslaved to OVS/bridge (no 'master' keyword),
# and not the loopback or virtual interfaces. The primary NIC is always enslaved to ovs-system
# on OCP nodes, so filtering by "no master" reliably selects the secondary.
SECONDARY_NIC=$(oc debug "node/${FIRST_NODE}" --quiet -- chroot /host \
  bash -c "
    ip -o link show | \
      grep -vE '(lo:|ovs-|br-|ovn|veth|genev|[0-9a-f]{15}|@)' | \
      grep -v 'master ' | \
      awk -F': ' '{print \$2}' | \
      head -1
  " 2>/dev/null || true)

if [[ -z "${SECONDARY_NIC}" ]]; then
  echo "    WARNING: Could not auto-detect secondary NIC."
  echo "    Defaulting to 'ens1'. Edit NNCP manifests if this is wrong."
  SECONDARY_NIC="ens1"
else
  echo "    Detected secondary NIC: ${SECONDARY_NIC}"
fi

# --- Apply OVS bridge NNCP ---
echo "--- Applying NNCP (OVS bridge on ${SECONDARY_NIC}) ---"

NNCP_FILE="${DEMO_DIR}/manifests/virt/nncp-ovs-bridge.yaml"
echo "    Applying ${NNCP_FILE} (replacing __SECONDARY_NIC__ with ${SECONDARY_NIC})..."
sed "s/__SECONDARY_NIC__/${SECONDARY_NIC}/g" "${NNCP_FILE}" | oc apply -f -

echo "--- Waiting for NNCP to be Available ---"
for i in $(seq 1 30); do
  ALL_AVAILABLE=true
  while read -r name status reason; do
    if [[ "${status}" != "True" ]]; then
      ALL_AVAILABLE=false
      echo "    ${name}: ${reason:-Pending} (Available=${status})"
    fi
  done < <(oc get nncp -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Available")].status}{"\t"}{.status.conditions[?(@.type=="Available")].reason}{"\n"}{end}' 2>/dev/null)

  if [[ "${ALL_AVAILABLE}" == "true" ]]; then
    echo "    All NNCPs are Available."
    break
  fi
  echo "    Waiting... (${i}/30)"
  sleep 20
done

# --- Set OVN bridge-mappings on each node ---
# Bridge-mappings are set via ovs-vsctl rather than the NNCP to avoid
# NMState verification conflicts with OVN-managed patch ports.
# Each tenant NAD has a unique localnet name so OVN creates separate
# logical switches and subnets.
BRIDGE_MAPPINGS="tenant-a-physnet:br-secondary,tenant-b-physnet:br-secondary"
echo "--- Configuring OVN bridge-mappings on each node ---"
for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
  echo "    Setting bridge-mappings on ${node}..."
  CURRENT=$(oc debug "node/${node}" --quiet -- chroot /host \
    ovs-vsctl get Open_vSwitch . external-ids:ovn-bridge-mappings 2>/dev/null || true)
  CURRENT="${CURRENT//\"/}"

  # Append our tenant mappings to any existing physnet mapping
  if [[ -z "${CURRENT}" || "${CURRENT}" == *"No such"* ]]; then
    NEW_MAPPINGS="${BRIDGE_MAPPINGS}"
  elif [[ "${CURRENT}" == *"tenant-a-physnet"* ]]; then
    echo "    Bridge-mappings already configured."
    continue
  else
    NEW_MAPPINGS="${CURRENT},${BRIDGE_MAPPINGS}"
  fi

  oc debug "node/${node}" --quiet -- chroot /host \
    ovs-vsctl set Open_vSwitch . external-ids:ovn-bridge-mappings="${NEW_MAPPINGS}" 2>/dev/null
  echo "    Done: ${NEW_MAPPINGS}"
done

# --- Create namespaces and NADs ---
echo "--- Creating tenant namespaces and OVN localnet NADs on infra cluster ---"
for tenant_dir in tenant-a tenant-b; do
  oc apply -f "${DEMO_DIR}/manifests/${tenant_dir}/namespace.yaml"
  oc apply -f "${DEMO_DIR}/manifests/${tenant_dir}/nad-"*.yaml
done

# --- Configure IP masquerade for external connectivity ---
echo "--- Configuring IP masquerade on bare-metal nodes ---"
echo "    OVN handles intra-VLAN L2 forwarding; masquerade provides outbound NAT"
echo "    so tenant VMs can reach the internet (image pulls, Konnectivity)."

TENANT_A_CIDR="10.100.30.0/24"
TENANT_B_CIDR="10.100.31.0/24"

for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
  echo "    Configuring ${node}..."
  oc debug "node/${node}" --quiet -- chroot /host bash -c "
    sysctl -w net.ipv4.ip_forward=1
    echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-hcp-demo-forward.conf

    PRIMARY_IF=\$(ip route show default | awk '{print \$5}' | head -1)

    if ! iptables -t nat -C POSTROUTING -s ${TENANT_A_CIDR} -o \${PRIMARY_IF} -j MASQUERADE 2>/dev/null; then
      iptables -t nat -A POSTROUTING -s ${TENANT_A_CIDR} -o \${PRIMARY_IF} -j MASQUERADE
    fi

    if ! iptables -t nat -C POSTROUTING -s ${TENANT_B_CIDR} -o \${PRIMARY_IF} -j MASQUERADE 2>/dev/null; then
      iptables -t nat -A POSTROUTING -s ${TENANT_B_CIDR} -o \${PRIMARY_IF} -j MASQUERADE
    fi
  " 2>/dev/null || echo "    WARNING: masquerade config may have failed on ${node}"
done

echo ""
echo "Secondary network configured (OVN localnet):"
echo "  - OVS bridge: br-secondary on ${SECONDARY_NIC}"
echo "  - OVN bridge-mappings: tenant-a-physnet, tenant-b-physnet -> br-secondary"
echo "  - Tenant A: OVN localnet VLAN 300 (10.100.30.0/24)"
echo "  - Tenant B: OVN localnet VLAN 301 (10.100.31.0/24)"
echo "  - IP masquerade for outbound NAT"
echo "  - Tenant VMs are live-migratable"
