#!/usr/bin/env bash
# uninstall-demo.sh -- Fast full teardown using direct AWS API calls.
#
# Instead of the slow openshift-install destroy (which can take 30+ min per
# cluster), this script directly terminates EC2 instances, deletes load
# balancers, NAT gateways, ENIs, security groups, and Route53 records, then
# runs Terraform destroy for the remaining VPC scaffolding. Total time is
# typically under 10 minutes.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP_DIR="${DEMO_DIR}/setup"
ENV_FILE="${SETUP_DIR}/.generated-infra.env"

[[ -f "${DEMO_DIR}/credentials.env" ]] && source "${DEMO_DIR}/credentials.env"
[[ -f "${ENV_FILE}" ]] && source "${ENV_FILE}"

REGION="${AWS_REGION:-us-east-2}"
VPC="${VPC_ID:-}"

echo "=== Full demo teardown (fast mode) ==="
echo ""
echo "WARNING: This will destroy ALL demo resources in AWS:"
echo "  - All EC2 instances (hub, infra, and tenant VMs)"
echo "  - All load balancers in the demo VPC"
echo "  - NAT gateways, Elastic IPs, ENIs, security groups"
echo "  - Route53 DNS records (hub, infra, tenants)"
echo "  - Terraform-managed VPC, subnets, internet gateway"
echo ""
if [[ -n "${VPC}" ]]; then
  echo "  VPC: ${VPC} (${REGION})"
fi
echo ""
read -rp "Type 'destroy' to confirm: " confirm
if [[ "${confirm}" != "destroy" ]]; then
  echo "Aborted."
  exit 0
fi

# Collect infra IDs from metadata.json files
HUB_INFRA_ID=""
VIRT_INFRA_ID=""
if [[ -f "${DEMO_DIR}/install-configs/hub/metadata.json" ]]; then
  HUB_INFRA_ID=$(python3 -c "import json; print(json.load(open('${DEMO_DIR}/install-configs/hub/metadata.json'))['infraID'])" 2>/dev/null || true)
fi
if [[ -f "${DEMO_DIR}/install-configs/virt/metadata.json" ]]; then
  VIRT_INFRA_ID=$(python3 -c "import json; print(json.load(open('${DEMO_DIR}/install-configs/virt/metadata.json'))['infraID'])" 2>/dev/null || true)
fi
echo ""
echo "  Hub infraID:  ${HUB_INFRA_ID:-unknown}"
echo "  Virt infraID: ${VIRT_INFRA_ID:-unknown}"

# ─── Step 1: Delete Route53 DNS records ──────────────────────────────
echo ""
echo "--- Step 1: Removing Route53 DNS records ---"
if [[ -n "${ROUTE53_ZONE_ID:-}" && -n "${BASE_DOMAIN:-}" ]]; then
  ALL_RECORDS=$(aws route53 list-resource-record-sets \
    --hosted-zone-id "${ROUTE53_ZONE_ID}" \
    --output json --region "${REGION}" 2>/dev/null || echo '{"ResourceRecordSets":[]}')

  DEMO_RECORDS=$(echo "${ALL_RECORDS}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
base = '${BASE_DOMAIN}'
skip_types = ['NS', 'SOA']
for r in data.get('ResourceRecordSets', []):
    name = r['Name'].rstrip('.')
    if r['Type'] in skip_types and name == base:
        continue
    if any(prefix in name for prefix in ['hub.', 'virt.', 'tenant-a.', 'tenant-b.']):
        print(json.dumps(r))
" 2>/dev/null || true)

  if [[ -n "${DEMO_RECORDS}" ]]; then
    while IFS= read -r record; do
      REC_NAME=$(echo "${record}" | python3 -c "import json,sys; print(json.load(sys.stdin)['Name'])")
      REC_TYPE=$(echo "${record}" | python3 -c "import json,sys; print(json.load(sys.stdin)['Type'])")

      if [[ "${REC_TYPE}" == "A" ]]; then
        ALIAS=$(echo "${record}" | python3 -c "import json,sys; r=json.load(sys.stdin); print('alias' if 'AliasTarget' in r else 'standard')")
        if [[ "${ALIAS}" == "alias" ]]; then
          ALIAS_DNS=$(echo "${record}" | python3 -c "import json,sys; print(json.load(sys.stdin)['AliasTarget']['DNSName'])")
          ALIAS_ZONE=$(echo "${record}" | python3 -c "import json,sys; print(json.load(sys.stdin)['AliasTarget']['HostedZoneId'])")
          echo "    Deleting alias A record: ${REC_NAME}"
          aws route53 change-resource-record-sets \
            --hosted-zone-id "${ROUTE53_ZONE_ID}" \
            --change-batch "{
              \"Changes\": [{
                \"Action\": \"DELETE\",
                \"ResourceRecordSet\": {
                  \"Name\": \"${REC_NAME}\",
                  \"Type\": \"A\",
                  \"AliasTarget\": {
                    \"HostedZoneId\": \"${ALIAS_ZONE}\",
                    \"DNSName\": \"${ALIAS_DNS}\",
                    \"EvaluateTargetHealth\": false
                  }
                }
              }]
            }" --region "${REGION}" >/dev/null 2>&1 || true
          continue
        fi
      fi

      REC_TTL=$(echo "${record}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('TTL',300))")
      RR_JSON=$(echo "${record}" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin).get('ResourceRecords',[])))")
      echo "    Deleting ${REC_TYPE} record: ${REC_NAME}"
      aws route53 change-resource-record-sets \
        --hosted-zone-id "${ROUTE53_ZONE_ID}" \
        --change-batch "{
          \"Changes\": [{
            \"Action\": \"DELETE\",
            \"ResourceRecordSet\": {
              \"Name\": \"${REC_NAME}\",
              \"Type\": \"${REC_TYPE}\",
              \"TTL\": ${REC_TTL},
              \"ResourceRecords\": ${RR_JSON}
            }
          }]
        }" --region "${REGION}" >/dev/null 2>&1 || true
    done <<< "${DEMO_RECORDS}"
  else
    echo "    No demo DNS records found."
  fi
else
  echo "    ROUTE53_ZONE_ID or BASE_DOMAIN not set. Skipping."
fi

# ─── Step 2: Terminate all EC2 instances in the VPC ──────────────────
echo ""
echo "--- Step 2: Terminating EC2 instances ---"
if [[ -n "${VPC}" ]]; then
  INSTANCE_IDS=$(aws ec2 describe-instances --region "${REGION}" \
    --filters "Name=vpc-id,Values=${VPC}" "Name=instance-state-name,Values=running,stopped,stopping,pending" \
    --query "Reservations[].Instances[].InstanceId" --output text 2>/dev/null || true)
  if [[ -n "${INSTANCE_IDS}" && "${INSTANCE_IDS}" != "None" ]]; then
    echo "    Terminating: ${INSTANCE_IDS}"
    aws ec2 terminate-instances --region "${REGION}" --instance-ids ${INSTANCE_IDS} >/dev/null 2>&1 || true
    echo "    Waiting for instances to terminate..."
    aws ec2 wait instance-terminated --region "${REGION}" --instance-ids ${INSTANCE_IDS} 2>/dev/null || true
    echo "    All instances terminated."
  else
    echo "    No instances found."
  fi
else
  echo "    VPC_ID not set. Skipping."
fi

# ─── Step 3: Delete load balancers ───────────────────────────────────
echo ""
echo "--- Step 3: Deleting load balancers ---"
if [[ -n "${VPC}" ]]; then
  FOUND_LB=false

  # Classic ELBs
  CLASSIC_ELBS=$(aws elb describe-load-balancers --region "${REGION}" \
    --query "LoadBalancerDescriptions[?VPCId=='${VPC}'].LoadBalancerName" --output text 2>/dev/null || true)
  for elb in ${CLASSIC_ELBS}; do
    [[ -z "${elb}" || "${elb}" == "None" ]] && continue
    echo "    Deleting classic ELB: ${elb}"
    aws elb delete-load-balancer --region "${REGION}" --load-balancer-name "${elb}" 2>/dev/null || true
    FOUND_LB=true
  done

  # ALB/NLB (v2)
  V2_ELBS=$(aws elbv2 describe-load-balancers --region "${REGION}" \
    --query "LoadBalancers[?VpcId=='${VPC}'].LoadBalancerArn" --output text 2>/dev/null || true)
  for arn in ${V2_ELBS}; do
    [[ -z "${arn}" || "${arn}" == "None" ]] && continue
    echo "    Deleting ELBv2: ${arn##*/}"
    aws elbv2 delete-load-balancer --region "${REGION}" --load-balancer-arn "${arn}" 2>/dev/null || true
    FOUND_LB=true
  done

  if [[ "${FOUND_LB}" == "true" ]]; then
    echo "    Waiting 15s for LB deletion to propagate..."
    sleep 15
  else
    echo "    No load balancers found."
  fi
fi

# ─── Step 4: Delete NAT gateways ────────────────────────────────────
echo ""
echo "--- Step 4: Deleting NAT gateways ---"
if [[ -n "${VPC}" ]]; then
  NAT_GWS=$(aws ec2 describe-nat-gateways --region "${REGION}" \
    --filter "Name=vpc-id,Values=${VPC}" "Name=state,Values=available,pending" \
    --query "NatGateways[].NatGatewayId" --output text 2>/dev/null || true)
  FOUND_NAT=false
  for ngw in ${NAT_GWS}; do
    [[ -z "${ngw}" || "${ngw}" == "None" ]] && continue
    echo "    Deleting NAT gateway: ${ngw}"
    aws ec2 delete-nat-gateway --region "${REGION}" --nat-gateway-id "${ngw}" >/dev/null 2>&1 || true
    FOUND_NAT=true
  done
  if [[ "${FOUND_NAT}" == "true" ]]; then
    echo "    Waiting for NAT gateways to delete..."
    for ngw in ${NAT_GWS}; do
      [[ -z "${ngw}" || "${ngw}" == "None" ]] && continue
      for i in $(seq 1 30); do
        STATE=$(aws ec2 describe-nat-gateways --region "${REGION}" \
          --nat-gateway-ids "${ngw}" --query "NatGateways[0].State" --output text 2>/dev/null || echo "deleted")
        [[ "${STATE}" == "deleted" || "${STATE}" == "None" ]] && break
        sleep 10
      done
    done
    echo "    NAT gateways deleted."
  else
    echo "    No NAT gateways found."
  fi
fi

# ─── Step 5: Release Elastic IPs ────────────────────────────────────
echo ""
echo "--- Step 5: Releasing Elastic IPs ---"
FOUND_EIP=false
for infra_id in "${HUB_INFRA_ID}" "${VIRT_INFRA_ID}"; do
  [[ -z "${infra_id}" ]] && continue
  EIPS=$(aws ec2 describe-addresses --region "${REGION}" \
    --filters "Name=tag-key,Values=kubernetes.io/cluster/${infra_id}" \
    --query "Addresses[].AllocationId" --output text 2>/dev/null || true)
  for alloc in ${EIPS}; do
    [[ -z "${alloc}" || "${alloc}" == "None" ]] && continue
    echo "    Releasing EIP: ${alloc} (${infra_id})"
    aws ec2 release-address --region "${REGION}" --allocation-id "${alloc}" 2>/dev/null || true
    FOUND_EIP=true
  done
done
# Terraform-tagged EIPs (NAT gateway)
TF_EIPS=$(aws ec2 describe-addresses --region "${REGION}" \
  --filters "Name=tag:managed-by,Values=terraform" \
  --query "Addresses[].AllocationId" --output text 2>/dev/null || true)
for alloc in ${TF_EIPS}; do
  [[ -z "${alloc}" || "${alloc}" == "None" ]] && continue
  echo "    Releasing EIP: ${alloc} (terraform)"
  aws ec2 release-address --region "${REGION}" --allocation-id "${alloc}" 2>/dev/null || true
  FOUND_EIP=true
done
if [[ "${FOUND_EIP}" == "false" ]]; then
  echo "    No Elastic IPs found."
fi

# ─── Step 6: Delete ENIs ────────────────────────────────────────────
echo ""
echo "--- Step 6: Deleting network interfaces ---"
if [[ -n "${VPC}" ]]; then
  DETACHED_IDS=()
  # Force-detach non-primary attached ENIs first
  ATTACHED_ENIS=$(aws ec2 describe-network-interfaces --region "${REGION}" \
    --filters "Name=vpc-id,Values=${VPC}" "Name=attachment.device-index,Values=1,2,3,4,5" \
    --query "NetworkInterfaces[].[NetworkInterfaceId,Attachment.AttachmentId]" --output text 2>/dev/null || true)
  while IFS=$'\t' read -r eni_id attach_id; do
    [[ -z "${eni_id}" || "${eni_id}" == "None" ]] && continue
    echo "    Force-detaching ENI: ${eni_id}"
    aws ec2 detach-network-interface --region "${REGION}" --attachment-id "${attach_id}" --force 2>/dev/null || true
    DETACHED_IDS+=("${eni_id}")
  done <<< "${ATTACHED_ENIS}"
  if [[ ${#DETACHED_IDS[@]} -gt 0 ]]; then
    echo "    Waiting for detach to complete..."
    for i in $(seq 1 12); do
      STILL_ATTACHED=$(aws ec2 describe-network-interfaces --region "${REGION}" \
        --network-interface-ids "${DETACHED_IDS[@]}" \
        --query "NetworkInterfaces[?Status!='available'].NetworkInterfaceId" --output text 2>/dev/null || true)
      [[ -z "${STILL_ATTACHED}" || "${STILL_ATTACHED}" == "None" ]] && break
      sleep 5
    done
    for eni_id in "${DETACHED_IDS[@]}"; do
      echo "    Deleting detached ENI: ${eni_id}"
      aws ec2 delete-network-interface --region "${REGION}" --network-interface-id "${eni_id}" 2>/dev/null || true
    done
  fi

  # Delete all remaining available (unattached) ENIs
  ENIS=$(aws ec2 describe-network-interfaces --region "${REGION}" \
    --filters "Name=vpc-id,Values=${VPC}" "Name=status,Values=available" \
    --query "NetworkInterfaces[].NetworkInterfaceId" --output text 2>/dev/null || true)
  FOUND_ENI=false
  for eni in ${ENIS}; do
    [[ -z "${eni}" || "${eni}" == "None" ]] && continue
    echo "    Deleting ENI: ${eni}"
    aws ec2 delete-network-interface --region "${REGION}" --network-interface-id "${eni}" 2>/dev/null || true
    FOUND_ENI=true
  done
  if [[ "${FOUND_ENI}" == "false" && ${#DETACHED_IDS[@]} -eq 0 ]]; then
    echo "    No orphaned ENIs found."
  fi
fi

# ─── Step 7: Delete security groups ─────────────────────────────────
echo ""
echo "--- Step 7: Deleting security groups ---"
if [[ -n "${VPC}" ]]; then
  SG_IDS=$(aws ec2 describe-security-groups --region "${REGION}" \
    --filters "Name=vpc-id,Values=${VPC}" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null || true)
  # Strip cross-SG references first so deletes succeed
  for sg in ${SG_IDS}; do
    [[ -z "${sg}" || "${sg}" == "None" ]] && continue
    INGRESS_RULES=$(aws ec2 describe-security-group-rules --region "${REGION}" \
      --filters "Name=group-id,Values=${sg}" \
      --query "SecurityGroupRules[?!IsEgress].SecurityGroupRuleId" --output text 2>/dev/null || true)
    for rule_id in ${INGRESS_RULES}; do
      [[ -z "${rule_id}" || "${rule_id}" == "None" ]] && continue
      aws ec2 revoke-security-group-ingress --region "${REGION}" --group-id "${sg}" --security-group-rule-ids "${rule_id}" >/dev/null 2>&1 || true
    done
    EGRESS_RULES=$(aws ec2 describe-security-group-rules --region "${REGION}" \
      --filters "Name=group-id,Values=${sg}" \
      --query "SecurityGroupRules[?IsEgress].SecurityGroupRuleId" --output text 2>/dev/null || true)
    for rule_id in ${EGRESS_RULES}; do
      [[ -z "${rule_id}" || "${rule_id}" == "None" ]] && continue
      aws ec2 revoke-security-group-egress --region "${REGION}" --group-id "${sg}" --security-group-rule-ids "${rule_id}" >/dev/null 2>&1 || true
    done
  done
  FOUND_SG=false
  for sg in ${SG_IDS}; do
    [[ -z "${sg}" || "${sg}" == "None" ]] && continue
    echo "    Deleting SG: ${sg}"
    aws ec2 delete-security-group --region "${REGION}" --group-id "${sg}" 2>/dev/null || true
    FOUND_SG=true
  done
  if [[ "${FOUND_SG}" == "false" ]]; then
    echo "    No security groups to delete."
  fi
fi

# ─── Step 8: Delete orphaned EBS volumes ─────────────────────────────
echo ""
echo "--- Step 8: Deleting orphaned EBS volumes ---"
FOUND_VOL=false
for infra_id in "${HUB_INFRA_ID}" "${VIRT_INFRA_ID}"; do
  [[ -z "${infra_id}" ]] && continue
  VOLS=$(aws ec2 describe-volumes --region "${REGION}" \
    --filters "Name=tag-key,Values=kubernetes.io/cluster/${infra_id}" "Name=status,Values=available" \
    --query "Volumes[].VolumeId" --output text 2>/dev/null || true)
  for vol in ${VOLS}; do
    [[ -z "${vol}" || "${vol}" == "None" ]] && continue
    echo "    Deleting volume: ${vol}"
    aws ec2 delete-volume --region "${REGION}" --volume-id "${vol}" 2>/dev/null || true
    FOUND_VOL=true
  done
done
if [[ "${FOUND_VOL}" == "false" ]]; then
  echo "    No orphaned volumes found."
fi

# ─── Step 9: Terraform destroy (VPC scaffolding) ────────────────────
echo ""
echo "--- Step 9: Destroying Terraform resources (VPC, subnets, IGW) ---"
cd "${DEMO_DIR}/terraform"
if [[ -d .terraform ]]; then
  terraform destroy -auto-approve || true
else
  echo "    Terraform not initialized. Skipping."
  echo "    You may need to manually delete VPC ${VPC} from the AWS console."
fi

# ─── Step 10: Clean up local files ──────────────────────────────────
echo ""
echo "--- Step 10: Cleaning up local generated files ---"
rm -f "${SETUP_DIR}"/.generated-*
rm -rf "${DEMO_DIR}/install-configs/hub"
rm -rf "${DEMO_DIR}/install-configs/virt"
rm -f "${DEMO_DIR}/terraform/terraform.tfvars"
echo "    Local state cleaned."

echo ""
echo "================================================================"
echo "  Teardown complete."
echo ""
echo "  Verify no resources remain in your AWS console:"
echo "    ${AWS_WEB_CONSOLE_URL:-https://console.aws.amazon.com}"
echo "================================================================"
