#!/usr/bin/env bash
# deploy-spoke.sh — Deploy customer (spoke) EKS cluster
#
# Usage:
#   ./scripts/deploy-spoke.sh --vpc-id <id> --subnet1 <id> --subnet2 <id> --subnet3 <id> \
#                             --hub-account <id> [OPTIONS]

set -euo pipefail

STACK_NAME="customer1-cluster"
REGION="ap-southeast-2"
PROFILE="customer1"  # Different profile for customer account
CLUSTER_NAME="customer1-prod"
CUSTOMER_NAME="customer1"
VPC_ID=""
SUBNET1="" SUBNET2="" SUBNET3=""
HUB_ACCOUNT=""
HUB_ECR_REGION="ap-southeast-2"
HUB_LOG_ROLE=""
HUB_PROM_ROLE=""
HUB_PROM_ENDPOINT=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
ok()   { echo "[$(date '+%H:%M:%S')] ✓ $*"; }
fail() { echo "[$(date '+%H:%M:%S')] ✗ $*" >&2; exit 1; }

# Try to load hub connection info
if [[ -f "${ROOT}/.hub-connection-info" ]]; then
  log "Loading hub connection info from .hub-connection-info..."
  # shellcheck disable=SC1091
  source "${ROOT}/.hub-connection-info"
  HUB_ACCOUNT="${HUB_ACCOUNT_ID}"
  HUB_ECR_REGION="${HUB_REGION}"
  HUB_LOG_ROLE="${HUB_LOG_ROLE}"
  HUB_PROM_ROLE="${HUB_PROMETHEUS_ROLE}"
  HUB_PROM_ENDPOINT="${HUB_PROMETHEUS_ENDPOINT}"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack-name)              STACK_NAME="$2";              shift 2 ;;
    --region)                  REGION="$2";                  shift 2 ;;
    --profile)                 PROFILE="$2";                 shift 2 ;;
    --cluster-name)            CLUSTER_NAME="$2";            shift 2 ;;
    --customer-name)           CUSTOMER_NAME="$2";           shift 2 ;;
    --vpc-id)                  VPC_ID="$2";                  shift 2 ;;
    --subnet1)                 SUBNET1="$2";                 shift 2 ;;
    --subnet2)                 SUBNET2="$2";                 shift 2 ;;
    --subnet3)                 SUBNET3="$2";                 shift 2 ;;
    --hub-account)             HUB_ACCOUNT="$2";             shift 2 ;;
    --hub-ecr-region)          HUB_ECR_REGION="$2";          shift 2 ;;
    --hub-logging-role)        HUB_LOG_ROLE="$2";            shift 2 ;;
    --hub-prometheus-role)     HUB_PROM_ROLE="$2";           shift 2 ;;
    --hub-prometheus-endpoint) HUB_PROM_ENDPOINT="$2";       shift 2 ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

AWS="aws --region ${REGION} --profile ${PROFILE}"

# Validate required parameters
[[ -z "${VPC_ID}" ]]     && fail "Missing --vpc-id"
[[ -z "${SUBNET1}" ]]    && fail "Missing --subnet1"
[[ -z "${SUBNET2}" ]]    && fail "Missing --subnet2"
[[ -z "${SUBNET3}" ]]    && fail "Missing --subnet3"
[[ -z "${HUB_ACCOUNT}" ]] && fail "Missing --hub-account"

log "Deploying customer cluster (spoke)..."
log "  Stack:     ${STACK_NAME}"
log "  Region:    ${REGION}"
log "  Cluster:   ${CLUSTER_NAME}"
log "  Customer:  ${CUSTOMER_NAME}"
log "  VPC:       ${VPC_ID}"
log "  Hub:       ${HUB_ACCOUNT}"

# Build parameter overrides
OVERRIDES="ClusterName=${CLUSTER_NAME} CustomerName=${CUSTOMER_NAME}"
OVERRIDES="${OVERRIDES} VpcId=${VPC_ID}"
OVERRIDES="${OVERRIDES} Subnet1Id=${SUBNET1}"
OVERRIDES="${OVERRIDES} Subnet2Id=${SUBNET2}"
OVERRIDES="${OVERRIDES} Subnet3Id=${SUBNET3}"
OVERRIDES="${OVERRIDES} HubAccountId=${HUB_ACCOUNT}"
OVERRIDES="${OVERRIDES} HubECRRegion=${HUB_ECR_REGION}"
[[ -n "${HUB_LOG_ROLE}" ]]       && OVERRIDES="${OVERRIDES} HubLoggingRoleArn=${HUB_LOG_ROLE}"
[[ -n "${HUB_PROM_ROLE}" ]]      && OVERRIDES="${OVERRIDES} HubPrometheusRoleArn=${HUB_PROM_ROLE}"
[[ -n "${HUB_PROM_ENDPOINT}" ]]  && OVERRIDES="${OVERRIDES} HubPrometheusEndpoint=${HUB_PROM_ENDPOINT}"

# Deploy CloudFormation stack
log "Deploying CloudFormation stack..."
# shellcheck disable=SC2086
${AWS} cloudformation deploy \
  --stack-name "${STACK_NAME}" \
  --template-file "${ROOT}/cfn/spoke-customer-cluster.yaml" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides ${OVERRIDES} \
  || fail "CloudFormation deploy failed"

ok "Spoke stack deployed"

# Get stack outputs
get_output() {
  ${AWS} cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text
}

CLUSTER_NAME=$(get_output ClusterName)
CLUSTER_ENDPOINT=$(get_output ClusterEndpoint)
NODE_ROLE=$(get_output NodeRoleArn)

# Update kubeconfig
log "Updating kubeconfig..."
${AWS} eks update-kubeconfig --name "${CLUSTER_NAME}"

kubectl cluster-info --request-timeout=10s \
  || fail "kubectl cannot reach the cluster"
ok "Cluster reachable"

# Wait for nodes to be ready
log "Waiting for nodes to be ready..."
for i in {1..30}; do
  READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo "0")
  if [[ "${READY_NODES}" -gt 0 ]]; then
    ok "${READY_NODES} node(s) ready"
    break
  fi
  [[ $i -eq 30 ]] && fail "Nodes did not become ready"
  sleep 10
done

# Display summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Customer Cluster Deployed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo " Cluster:"
echo "   Name:       ${CLUSTER_NAME}"
echo "   Customer:   ${CUSTOMER_NAME}"
echo "   Endpoint:   ${CLUSTER_ENDPOINT}"
echo "   Region:     ${REGION}"
echo ""
echo " Hub Connection:"
echo "   Hub Account: ${HUB_ACCOUNT}"
echo "   ECR Region:  ${HUB_ECR_REGION}"
[[ -n "${HUB_LOG_ROLE}" ]] && echo "   Logging:     ✓ Connected"
[[ -n "${HUB_PROM_ROLE}" ]] && echo "   Monitoring:  ✓ Connected"
echo ""
echo " Nodes:"
kubectl get nodes
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo " Next Steps:"
echo ""
echo " 1. Deploy application using hub ECR images:"
echo "    kubectl apply -f - <<EOF"
echo "    apiVersion: apps/v1"
echo "    kind: Deployment"
echo "    metadata:"
echo "      name: myapp"
echo "    spec:"
echo "      replicas: 2"
echo "      selector:"
echo "        matchLabels:"
echo "          app: myapp"
echo "      template:"
echo "        metadata:"
echo "          labels:"
echo "            app: myapp"
echo "        spec:"
echo "          containers:"
echo "          - name: app"
echo "            image: ${HUB_ACCOUNT}.dkr.ecr.${HUB_ECR_REGION}.amazonaws.com/shared/myapp:latest"
echo "    EOF"
echo ""
if [[ -n "${HUB_LOG_ROLE}" ]]; then
  echo " 2. Deploy FluentBit for centralized logging:"
  echo "    kubectl apply -f ${ROOT}/manifests/fluentbit-hub.yaml"
  echo ""
fi
if [[ -n "${HUB_PROM_ROLE}" ]]; then
  echo " 3. Deploy Prometheus for centralized monitoring:"
  echo "    kubectl apply -f ${ROOT}/manifests/prometheus-hub.yaml"
  echo ""
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
