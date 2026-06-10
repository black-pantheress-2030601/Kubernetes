#!/usr/bin/env bash
# deploy-hub.sh — Deploy shared services hub account
#
# Usage:
#   ./scripts/deploy-hub.sh --vpc-id <id> --subnet1 <id> --subnet2 <id> --subnet3 <id> \
#                           --customer1-account <id> [OPTIONS]

set -euo pipefail

STACK_NAME="shared-services-hub"
REGION="ap-southeast-2"
PROFILE="WorkloadConfig"
CLUSTER_NAME="shared-services-hub"
DEPLOY_CLUSTER="true"
VPC_ID=""
SUBNET1="" SUBNET2="" SUBNET3=""
CUSTOMER1_ACCOUNT=""
CUSTOMER2_ACCOUNT=""
CUSTOMER3_ACCOUNT=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
ok()   { echo "[$(date '+%H:%M:%S')] ✓ $*"; }
fail() { echo "[$(date '+%H:%M:%S')] ✗ $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack-name)          STACK_NAME="$2";          shift 2 ;;
    --region)              REGION="$2";              shift 2 ;;
    --profile)             PROFILE="$2";             shift 2 ;;
    --cluster-name)        CLUSTER_NAME="$2";        shift 2 ;;
    --vpc-id)              VPC_ID="$2";              shift 2 ;;
    --subnet1)             SUBNET1="$2";             shift 2 ;;
    --subnet2)             SUBNET2="$2";             shift 2 ;;
    --subnet3)             SUBNET3="$2";             shift 2 ;;
    --customer1-account)   CUSTOMER1_ACCOUNT="$2";   shift 2 ;;
    --customer2-account)   CUSTOMER2_ACCOUNT="$2";   shift 2 ;;
    --customer3-account)   CUSTOMER3_ACCOUNT="$2";   shift 2 ;;
    --no-cluster)          DEPLOY_CLUSTER="false";   shift ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

AWS="aws --region ${REGION} --profile ${PROFILE}"

# Validate required parameters
[[ -z "${VPC_ID}" ]]   && fail "Missing --vpc-id"
[[ -z "${SUBNET1}" ]]  && fail "Missing --subnet1"
[[ -z "${SUBNET2}" ]]  && fail "Missing --subnet2"
[[ -z "${SUBNET3}" ]]  && fail "Missing --subnet3"
[[ -z "${CUSTOMER1_ACCOUNT}" ]] && fail "Missing --customer1-account (at least one customer required)"

log "Deploying hub account infrastructure..."
log "  Stack:     ${STACK_NAME}"
log "  Region:    ${REGION}"
log "  Cluster:   ${CLUSTER_NAME}"
log "  VPC:       ${VPC_ID}"
log "  Customers: ${CUSTOMER1_ACCOUNT} ${CUSTOMER2_ACCOUNT} ${CUSTOMER3_ACCOUNT}"

# Build parameter overrides
OVERRIDES="ClusterName=${CLUSTER_NAME} DeploySharedCluster=${DEPLOY_CLUSTER}"
OVERRIDES="${OVERRIDES} VpcId=${VPC_ID}"
OVERRIDES="${OVERRIDES} Subnet1Id=${SUBNET1}"
OVERRIDES="${OVERRIDES} Subnet2Id=${SUBNET2}"
OVERRIDES="${OVERRIDES} Subnet3Id=${SUBNET3}"
OVERRIDES="${OVERRIDES} Customer1AccountId=${CUSTOMER1_ACCOUNT}"
[[ -n "${CUSTOMER2_ACCOUNT}" ]] && OVERRIDES="${OVERRIDES} Customer2AccountId=${CUSTOMER2_ACCOUNT}"
[[ -n "${CUSTOMER3_ACCOUNT}" ]] && OVERRIDES="${OVERRIDES} Customer3AccountId=${CUSTOMER3_ACCOUNT}"

# Deploy CloudFormation stack
log "Deploying CloudFormation stack..."
# shellcheck disable=SC2086
${AWS} cloudformation deploy \
  --stack-name "${STACK_NAME}" \
  --template-file "${ROOT}/cfn/hub-shared-services.yaml" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides ${OVERRIDES} \
  || fail "CloudFormation deploy failed"

ok "Hub stack deployed"

# Get stack outputs
get_output() {
  ${AWS} cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text
}

ECR_IMAGES=$(get_output SharedImagesRepositoryUri)
ECR_PLATFORM=$(get_output SharedPlatformRepositoryUri)
LOG_GROUP=$(get_output CentralizedLogGroupName 2>/dev/null || echo "N/A")
LOG_ROLE=$(get_output CrossAccountLoggingRoleArn 2>/dev/null || echo "N/A")
PROM_WORKSPACE=$(get_output PrometheusWorkspaceId 2>/dev/null || echo "N/A")
PROM_ENDPOINT=$(get_output PrometheusEndpoint 2>/dev/null || echo "N/A")
PROM_ROLE=$(get_output CrossAccountPrometheusRoleArn 2>/dev/null || echo "N/A")

# Update kubeconfig if cluster was deployed
if [[ "${DEPLOY_CLUSTER}" == "true" ]]; then
  log "Updating kubeconfig..."
  ${AWS} eks update-kubeconfig --name "${CLUSTER_NAME}"

  kubectl cluster-info --request-timeout=10s \
    || fail "kubectl cannot reach the cluster"
  ok "Cluster reachable"
fi

# Display summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Hub Account Deployed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo " Container Registries:"
echo "   Shared Images:  ${ECR_IMAGES}"
echo "   Platform:       ${ECR_PLATFORM}"
echo ""
echo " Centralized Logging:"
echo "   Log Group:      ${LOG_GROUP}"
echo "   Cross-Acct Role: ${LOG_ROLE}"
echo ""
echo " Centralized Monitoring:"
echo "   Workspace ID:   ${PROM_WORKSPACE}"
echo "   Endpoint:       ${PROM_ENDPOINT}"
echo "   Cross-Acct Role: ${PROM_ROLE}"
echo ""
if [[ "${DEPLOY_CLUSTER}" == "true" ]]; then
  CLUSTER_ENDPOINT=$(get_output ClusterEndpoint)
  echo " Shared Services Cluster:"
  echo "   Name:     ${CLUSTER_NAME}"
  echo "   Endpoint: ${CLUSTER_ENDPOINT}"
  echo ""
fi
echo " Customer Accounts with Access:"
echo "   Customer 1: ${CUSTOMER1_ACCOUNT}"
[[ -n "${CUSTOMER2_ACCOUNT}" ]] && echo "   Customer 2: ${CUSTOMER2_ACCOUNT}"
[[ -n "${CUSTOMER3_ACCOUNT}" ]] && echo "   Customer 3: ${CUSTOMER3_ACCOUNT}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo " Next Steps:"
echo ""
echo " 1. Push container images to ECR:"
echo "    aws ecr get-login-password --region ${REGION} \\"
echo "      | docker login --username AWS --password-stdin ${ECR_IMAGES%%/*}"
echo "    docker tag myapp:latest ${ECR_IMAGES%%/shared*}/shared/myapp:latest"
echo "    docker push ${ECR_IMAGES%%/shared*}/shared/myapp:latest"
echo ""
echo " 2. Deploy customer cluster in customer account:"
echo "    ./scripts/deploy-spoke.sh \\"
echo "      --hub-account ${AWS_ACCOUNT_ID} \\"
echo "      --hub-logging-role ${LOG_ROLE} \\"
echo "      --hub-prometheus-role ${PROM_ROLE} \\"
echo "      --hub-prometheus-endpoint ${PROM_ENDPOINT} \\"
echo "      --vpc-id <vpc> --subnet1 <s1> --subnet2 <s2> --subnet3 <s3>"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Save connection info for spoke deployment
cat > "${ROOT}/.hub-connection-info" << EOF
HUB_ACCOUNT_ID=${AWS_ACCOUNT_ID:-$(${AWS} sts get-caller-identity --query Account --output text)}
HUB_REGION=${REGION}
HUB_ECR_IMAGES=${ECR_IMAGES}
HUB_ECR_PLATFORM=${ECR_PLATFORM}
HUB_LOG_ROLE=${LOG_ROLE}
HUB_PROMETHEUS_ROLE=${PROM_ROLE}
HUB_PROMETHEUS_ENDPOINT=${PROM_ENDPOINT}
EOF

ok "Hub connection info saved to .hub-connection-info"
