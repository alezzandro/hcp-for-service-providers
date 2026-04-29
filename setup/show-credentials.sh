#!/usr/bin/env bash
# show-credentials.sh -- Display all URLs, credentials, and infrastructure
# details needed when presenting the HCP Network Isolation demo.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP_DIR="${DEMO_DIR}/setup"
ENV_FILE="${SETUP_DIR}/.generated-infra.env"
NICS_FILE="${SETUP_DIR}/.generated-secondary-nics.env"

[[ -f "${DEMO_DIR}/credentials.env" ]] && source "${DEMO_DIR}/credentials.env"
[[ -f "${ENV_FILE}" ]]                  && source "${ENV_FILE}"
[[ -f "${NICS_FILE}" ]]                 && source "${NICS_FILE}"

BOLD="\033[1m"
DIM="\033[2m"
CYAN="\033[36m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

section() { printf "\n${BOLD}${CYAN}═══ %s ═══${RESET}\n" "$1"; }
label()   { printf "  ${BOLD}%-18s${RESET} %s\n" "$1" "$2"; }
warn()    { printf "  ${YELLOW}%-18s${RESET} %s\n" "$1" "$2"; }
dimline() { printf "  ${DIM}%s${RESET}\n" "$1"; }

printf "${BOLD}${GREEN}"
cat <<'BANNER'

  ╔═══════════════════════════════════════════════════════════════╗
  ║   HCP Network Isolation Demo — Infrastructure Dashboard      ║
  ╚═══════════════════════════════════════════════════════════════╝
BANNER
printf "${RESET}"

# ─── AWS / Terraform ────────────────────────────────────────────
section "AWS Infrastructure"
label "Region:"          "${AWS_DEFAULT_REGION:-unknown}"
label "Account ID:"      "${AWS_ACCOUNT_ID:-unknown}"
label "Base Domain:"     "${BASE_DOMAIN:-unknown}"
label "Route53 Zone:"    "${ROUTE53_ZONE_ID:-unknown}"
label "VPC ID:"          "${VPC_ID:-unknown}"

if [[ -n "${AWS_WEB_CONSOLE_URL:-}" ]]; then
  label "AWS Console:"   "${AWS_WEB_CONSOLE_URL}"
  label "  User:"        "${AWS_WEB_CONSOLE_USER:-n/a}"
  label "  Password:"    "${AWS_WEB_CONSOLE_PASS:-n/a}"
fi

# ─── Hub Cluster ────────────────────────────────────────────────
section "Hub Cluster  (ACM + HyperShift)"
HUB_KC="${SETUP_DIR}/.generated-hub-kubeconfig"
if [[ -f "${HUB_KC}" ]]; then
  HUB_API=$(KUBECONFIG="${HUB_KC}" oc whoami --show-server 2>/dev/null || echo "unknown")
  HUB_CONSOLE=$(KUBECONFIG="${HUB_KC}" oc whoami --show-console 2>/dev/null || echo "unknown")
  HUB_PASS=$(cat "${DEMO_DIR}/install-configs/hub/auth/kubeadmin-password" 2>/dev/null || echo "(see install dir)")
  HUB_VERSION=$(KUBECONFIG="${HUB_KC}" oc get clusterversion -o jsonpath='{.items[0].status.desired.version}' 2>/dev/null || echo "unknown")
  HUB_NODES=$(KUBECONFIG="${HUB_KC}" oc get nodes --no-headers 2>/dev/null | wc -l)
  ACM_STATUS=$(KUBECONFIG="${HUB_KC}" oc get multiclusterhub -n open-cluster-management -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "n/a")
  HS_READY=$(KUBECONFIG="${HUB_KC}" oc get pods -n hypershift -l app=operator --no-headers 2>/dev/null | grep -c Running || echo "0")

  label "API Server:"    "${HUB_API}"
  label "Web Console:"   "${HUB_CONSOLE}"
  label "Login:"         "kubeadmin / ${HUB_PASS}"
  label "OCP Version:"   "${HUB_VERSION}"
  label "Topology:"      "${HUB_NODES}-node compact"
  label "ACM Status:"    "${ACM_STATUS}"
  label "HyperShift:"    "${HS_READY} operator pod(s) Running"
  label "Kubeconfig:"    "${HUB_KC}"

  HC_LIST=$(KUBECONFIG="${HUB_KC}" oc get hostedcluster -n clusters --no-headers 2>/dev/null || true)
  if [[ -n "${HC_LIST}" ]]; then
    dimline ""
    dimline "Hosted Clusters managed from this hub:"
    echo "${HC_LIST}" | while read -r name ns ver available rest; do
      label "  ${name}:" "Available=${available}"
    done
  fi
else
  warn "(not installed)" ""
fi

# ─── Infrastructure (Virt) Cluster ──────────────────────────────
section "Infrastructure Cluster  (OCP Virtualization)"
VIRT_KC="${SETUP_DIR}/.generated-virt-kubeconfig"
if [[ -f "${VIRT_KC}" ]]; then
  VIRT_API=$(KUBECONFIG="${VIRT_KC}" oc whoami --show-server 2>/dev/null || echo "unknown")
  VIRT_CONSOLE=$(KUBECONFIG="${VIRT_KC}" oc whoami --show-console 2>/dev/null || echo "unknown")
  VIRT_PASS=$(cat "${DEMO_DIR}/install-configs/virt/auth/kubeadmin-password" 2>/dev/null || echo "(see install dir)")
  VIRT_VERSION=$(KUBECONFIG="${VIRT_KC}" oc get clusterversion -o jsonpath='{.items[0].status.desired.version}' 2>/dev/null || echo "unknown")
  VIRT_NODES=$(KUBECONFIG="${VIRT_KC}" oc get nodes --no-headers 2>/dev/null | wc -l)
  CNV_OK=$(KUBECONFIG="${VIRT_KC}" oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "n/a")
  NMS_OK=$(KUBECONFIG="${VIRT_KC}" oc get nmstate nmstate \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "n/a")

  label "API Server:"    "${VIRT_API}"
  label "Web Console:"   "${VIRT_CONSOLE}"
  label "Login:"         "kubeadmin / ${VIRT_PASS}"
  label "OCP Version:"   "${VIRT_VERSION}"
  label "Topology:"      "${VIRT_NODES}-node compact (m5.metal)"
  label "OCP Virt:"      "Available=${CNV_OK}"
  label "NMState:"       "Available=${NMS_OK}"
  label "Kubeconfig:"    "${VIRT_KC}"

  # Secondary NIC / OVN localnet
  NNCP_INFO=$(KUBECONFIG="${VIRT_KC}" oc get nncp --no-headers 2>/dev/null || true)
  if [[ -n "${NNCP_INFO}" ]]; then
    dimline ""
    dimline "OVN LocalNet (NMState NNCPs):"
    echo "${NNCP_INFO}" | while read -r name status rest; do
      label "  ${name}:" "${status}"
    done
  fi

  # Tenant VMs
  VMI_INFO=$(KUBECONFIG="${VIRT_KC}" oc get vmi -A --no-headers 2>/dev/null || true)
  if [[ -n "${VMI_INFO}" ]]; then
    dimline ""
    dimline "Tenant Worker VMs:"
    echo "${VMI_INFO}" | while read -r ns name age phase ip node ready; do
      label "  ${ns}/${name}:" "${phase}  IP=${ip}  Node=${node}"
    done
  fi
else
  warn "(not installed)" ""
fi

# ─── Tenant Clusters ────────────────────────────────────────────
for tenant in tenant-a tenant-b; do
  section "Tenant Cluster: ${tenant}"
  TENANT_KC="${SETUP_DIR}/.generated-${tenant}-kubeconfig"

  if [[ ! -f "${TENANT_KC}" ]]; then
    warn "(not provisioned)" ""
    continue
  fi

  TENANT_API_RAW=$(KUBECONFIG="${TENANT_KC}" timeout 8 oc whoami --show-server 2>/dev/null || echo "unknown")
  TENANT_API_DNS="https://api.${tenant}.${BASE_DOMAIN:-unknown}:6443"
  TENANT_CONSOLE="https://console-openshift-console.apps.${tenant}.${BASE_DOMAIN:-unknown}"
  TENANT_OAUTH="https://oauth-clusters-${tenant}.apps.hub.${BASE_DOMAIN:-unknown}"

  # MetalLB VIP (OVN localnet VLAN)
  METALLB_VIP=$(KUBECONFIG="${TENANT_KC}" timeout 8 oc get svc metallb-ingress -n openshift-ingress \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "n/a")

  # Apps ELB (mirrored on infra cluster)
  APPS_ELB=""
  if [[ -f "${VIRT_KC}" ]]; then
    APPS_ELB=$(KUBECONFIG="${VIRT_KC}" oc get svc -n "clusters-${tenant}" \
      -l "cluster.x-k8s.io/tenant-service-name=metallb-ingress" \
      -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  fi

  # Node count
  NODE_INFO=$(KUBECONFIG="${TENANT_KC}" timeout 8 oc get nodes --no-headers 2>/dev/null || true)
  NODE_COUNT=$(echo "${NODE_INFO}" | grep -c . 2>/dev/null || echo "0")

  # Version (from the hub's HostedCluster)
  TENANT_VER=""
  if [[ -f "${HUB_KC}" ]]; then
    TENANT_VER=$(KUBECONFIG="${HUB_KC}" oc get hostedcluster "${tenant}" -n clusters \
      -o jsonpath='{.status.version.history[0].version}' 2>/dev/null || echo "unknown")
  fi

  label "API Server:"    "${TENANT_API_DNS}"
  if [[ "${TENANT_API_RAW}" != *"${tenant}"* ]]; then
    dimline "  (kubeconfig uses: ${TENANT_API_RAW})"
  fi
  label "Console:"       "${TENANT_CONSOLE}"
  label "OAuth:"         "${TENANT_OAUTH}"
  label "OCP Version:"   "${TENANT_VER:-unknown}"
  label "Workers:"       "${NODE_COUNT} VM(s)"
  label "MetalLB VIP:"   "${METALLB_VIP}  (OVN localnet VLAN)"
  if [[ -n "${APPS_ELB}" ]]; then
    label "Apps ELB:"    "${APPS_ELB}"
  fi
  label "Apps Wildcard:"  "*.apps.${tenant}.${BASE_DOMAIN:-unknown}"
  label "Kubeconfig:"    "${TENANT_KC}"

  if [[ -n "${NODE_INFO}" ]]; then
    dimline ""
    dimline "Nodes:"
    echo "${NODE_INFO}" | while read -r nname nstatus nroles nage nver; do
      label "  ${nname}:" "${nstatus}  ${nver}"
    done
  fi

  # EgressFirewall
  EF=$(KUBECONFIG="${TENANT_KC}" timeout 8 oc get egressfirewall -n customer-workloads --no-headers 2>/dev/null || true)
  if [[ -n "${EF}" ]]; then
    dimline ""
    dimline "Security:"
    label "  EgressFirewall:" "Applied in customer-workloads"
  fi
done

# ─── EFS / Live Migration ────────────────────────────────────────
section "Live Migration (EFS)"
if [[ "${ENABLE_EFS_LIVE_MIGRATION:-false}" == "true" ]]; then
  label "EFS Mode:"       "ENABLED"
  label "EFS FS ID:"      "${EFS_FILESYSTEM_ID:-unknown}"
  label "StorageClass:"   "efs-sc (efs.csi.aws.com)"
  label "Root Vol Mode:"  "Filesystem / ReadWriteMany"

  if [[ -f "${VIRT_KC}" ]]; then
    EFS_SC=$(KUBECONFIG="${VIRT_KC}" oc get sc efs-sc --no-headers 2>/dev/null || true)
    if [[ -n "${EFS_SC}" ]]; then
      label "SC Status:"  "Present on infra cluster"
    else
      warn "SC Status:"   "NOT FOUND on infra cluster -- run 06b-install-efs-csi.sh"
    fi
  fi
else
  label "EFS Mode:"       "DISABLED (default EBS gp3-csi / RWO)"
  dimline "Set ENABLE_EFS_LIVE_MIGRATION=\"true\" in credentials.env to enable."
fi

# ─── Security Policies ──────────────────────────────────────────
section "Security Policies"
if [[ -f "${HUB_KC}" ]]; then
  ANP=$(KUBECONFIG="${HUB_KC}" oc get adminnetworkpolicy --no-headers 2>/dev/null || true)
  if [[ -n "${ANP}" ]]; then
    echo "${ANP}" | while read -r name prio rest; do
      label "Hub ANP:"     "${name} (priority ${prio})"
    done
  else
    warn "Hub ANP:"      "(none applied)"
  fi
else
  warn "Hub ANP:"        "(hub not available)"
fi

# ─── Quick-Access Commands ──────────────────────────────────────
section "Quick-Access Commands"
dimline "Switch cluster context with:"
echo ""
printf "  ${BOLD}# Hub${RESET}\n"
printf "  export KUBECONFIG=%s\n\n" "${HUB_KC}"
printf "  ${BOLD}# Infrastructure (Virt)${RESET}\n"
printf "  export KUBECONFIG=%s\n\n" "${VIRT_KC}"
printf "  ${BOLD}# Tenant A${RESET}\n"
printf "  export KUBECONFIG=%s\n\n" "${SETUP_DIR}/.generated-tenant-a-kubeconfig"
printf "  ${BOLD}# Tenant B${RESET}\n"
printf "  export KUBECONFIG=%s\n\n" "${SETUP_DIR}/.generated-tenant-b-kubeconfig"

printf "${BOLD}${GREEN}"
cat <<'FOOTER'
  ╔═══════════════════════════════════════════════════════════════╗
  ║   Tip: pipe through 'less -R' to scroll with colour          ║
  ╚═══════════════════════════════════════════════════════════════╝
FOOTER
printf "${RESET}\n"
