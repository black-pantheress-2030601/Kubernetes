#!/usr/bin/env bash
# deploy.sh — deploys the EKS cluster + identity + BRUPOP.
#
# Usage:
#   ./scripts/deploy.sh --vpc-id <id> --subnet1 <id> --subnet2 <id> --subnet3 <id> [OPTIONS]
#
# Options:
#   --stack-name   NAME     CloudFormation stack name (default: eks-identity)
#   --region       REGION   AWS region (default: ap-southeast-2)
#   --profile      PROFILE  AWS CLI profile (default: WorkloadConfig)
#   --vpc-id       ID       Existing VPC ID (required on first deploy)
#   --subnet1/2/3  ID       Subnet IDs (required on first deploy)
#   --cfn-only              Deploy CFN stack only, skip kubectl
#   --k8s-only              Skip CFN, apply kubectl manifests only
#   --skip-brupop           Skip cert-manager and BRUPOP install

set -euo pipefail

STACK_NAME="eks-identity"
REGION="ap-southeast-2"
PROFILE="WorkloadConfig"
VPC_ID=""
SUBNET1="" SUBNET2="" SUBNET3=""
CFN_ONLY=false
K8S_ONLY=false
SKIP_BRUPOP=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# cert-manager version to install before BRUPOP
CERT_MANAGER_VERSION="v1.14.5"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack-name)   STACK_NAME="$2";   shift 2 ;;
    --region)       REGION="$2";       shift 2 ;;
    --profile)      PROFILE="$2";      shift 2 ;;
    --vpc-id)       VPC_ID="$2";       shift 2 ;;
    --subnet1)      SUBNET1="$2";      shift 2 ;;
    --subnet2)      SUBNET2="$2";      shift 2 ;;
    --subnet3)      SUBNET3="$2";      shift 2 ;;
    --cfn-only)     CFN_ONLY=true;     shift ;;
    --k8s-only)     K8S_ONLY=true;     shift ;;
    --skip-brupop)  SKIP_BRUPOP=true;  shift ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

AWS="aws --region ${REGION} --profile ${PROFILE}"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
ok()   { echo "[$(date '+%H:%M:%S')] ✓ $*"; }
fail() { echo "[$(date '+%H:%M:%S')] ✗ $*" >&2; exit 1; }

cfn_out() { ${AWS} cloudformation describe-stacks --stack-name "${STACK_NAME}" \
              --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }

# ---------------------------------------------------------------------------
# Step 1 — CloudFormation
# ---------------------------------------------------------------------------
if [[ "${K8S_ONLY}" == false ]]; then
  log "Deploying CFN stack '${STACK_NAME}'..."

  OVERRIDES="ClusterName=${STACK_NAME}"
  [[ -n "${VPC_ID}" ]]  && OVERRIDES="${OVERRIDES} VpcId=${VPC_ID}"
  [[ -n "${SUBNET1}" ]] && OVERRIDES="${OVERRIDES} Subnet1Id=${SUBNET1}"
  [[ -n "${SUBNET2}" ]] && OVERRIDES="${OVERRIDES} Subnet2Id=${SUBNET2}"
  [[ -n "${SUBNET3}" ]] && OVERRIDES="${OVERRIDES} Subnet3Id=${SUBNET3}"

  # shellcheck disable=SC2086
  ${AWS} cloudformation deploy \
    --stack-name "${STACK_NAME}" \
    --template-file "${ROOT}/cfn/identity.yaml" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides ${OVERRIDES} \
    || fail "CFN deploy failed"

  ok "CFN stack deployed"
fi

# ---------------------------------------------------------------------------
# Step 2 — kubeconfig
# ---------------------------------------------------------------------------
CLUSTER_NAME="$(cfn_out ClusterName)"
[[ -z "${CLUSTER_NAME}" ]] && fail "Could not read ClusterName from stack outputs"

log "Updating kubeconfig for '${CLUSTER_NAME}'..."
${AWS} eks update-kubeconfig --name "${CLUSTER_NAME}"

kubectl cluster-info --request-timeout=10s \
  || fail "kubectl cannot reach the cluster endpoint"
ok "Cluster reachable"

[[ "${CFN_ONLY}" == true ]] && { log "CFN-only mode — done."; exit 0; }

# ---------------------------------------------------------------------------
# Step 3 — Kubernetes manifests
# ---------------------------------------------------------------------------
log "Applying namespaces..."
kubectl apply -f "${ROOT}/modules/namespaces.yaml"

log "Applying RBAC..."
kubectl apply -f "${ROOT}/modules/rbac.yaml"

ok "Identity manifests applied"

# ---------------------------------------------------------------------------
# Step 4 — cert-manager (prerequisite for BRUPOP)
# ---------------------------------------------------------------------------
if [[ "${SKIP_BRUPOP}" == false ]]; then
  log "Installing cert-manager ${CERT_MANAGER_VERSION}..."
  kubectl apply -f \
    "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"

  log "Waiting for cert-manager webhooks to be ready (up to 90s)..."
  kubectl rollout status deployment/cert-manager          -n cert-manager --timeout=90s
  kubectl rollout status deployment/cert-manager-webhook  -n cert-manager --timeout=90s
  kubectl rollout status deployment/cert-manager-cainjector -n cert-manager --timeout=90s
  ok "cert-manager ready"

  # ---------------------------------------------------------------------------
  # Step 5 — BRUPOP (Bottlerocket Update Operator)
  # ---------------------------------------------------------------------------
  log "Applying BRUPOP v1.3.0..."
  kubectl apply -f "${ROOT}/modules/brupop/brupop.yaml"

  log "Waiting for BRUPOP controller to be ready (up to 120s)..."
  kubectl rollout status deployment/brupop-controller-deployment \
    -n brupop-bottlerocket-aws --timeout=120s
  kubectl rollout status deployment/brupop-apiserver \
    -n brupop-bottlerocket-aws --timeout=120s
  ok "BRUPOP ready"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Cluster:   ${CLUSTER_NAME}"
echo " Endpoint:  $(cfn_out ClusterEndpoint)"
echo " Region:    ${REGION}"
echo ""
echo " Tenant namespaces:"
kubectl get ns -l isolation=strict --no-headers 2>/dev/null | awk '{print "   " $1}' || true
echo ""
if [[ "${SKIP_BRUPOP}" == false ]]; then
  echo " BRUPOP agent status (one pod per Bottlerocket node):"
  kubectl get ds brupop-agent -n brupop-bottlerocket-aws --no-headers 2>/dev/null \
    | awk '{print "   desired=" $2 "  ready=" $4}' || true
  echo ""
fi
echo " CA data (not in CFN outputs — fetch with):"
echo "   aws eks describe-cluster --name ${CLUSTER_NAME} \\"
echo "     --region ${REGION} --profile ${PROFILE} \\"
echo "     --query 'cluster.certificateAuthority.data' --output text"
echo ""
echo " To validate a tenant role binding:"
echo "   kubectl auth can-i get pods --namespace tenant-customer1 \\"
echo "     --as-group tenant:customer1 --as nobody"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
