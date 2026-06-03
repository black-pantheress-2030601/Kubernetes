#!/usr/bin/env bash
# deploy.sh — deploys the private EKS multi-tenant cluster end-to-end.
#
# IMPORTANT — private cluster:
#   The EKS API server endpoint is private-only. This script must run from
#   inside the VPC or from a machine with network access to the private
#   endpoint (VPN, Direct Connect, or AWS SSM Session Manager on a bastion).
#   AWS CLI calls (CloudFormation, EKS describe) work from anywhere because
#   they use the public AWS service endpoints. Only kubectl needs VPC access.
#
# Usage:
#   ./scripts/deploy.sh [OPTIONS]
#
# Options:
#   --stack-name   NAME      CloudFormation stack name (default: eks-multitenant)
#   --region       REGION    AWS region (default: us-east-1)
#   --profile      PROFILE   AWS CLI profile (default: default)
#   --vpc-id       VPC_ID    Existing VPC ID (required on first deploy)
#   --subnet1      SUBNET1   Private subnet ID in AZ-1 (required on first deploy)
#   --subnet2      SUBNET2   Private subnet ID in AZ-2 (required on first deploy)
#   --subnet3      SUBNET3   Private subnet ID in AZ-3 (required on first deploy)
#   --k8s-only               Skip CFN — only apply/update kubectl manifests
#   --cfn-only               Only deploy CFN, skip kubectl manifests
#   --help                   Print this message

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
STACK_NAME="${STACK_NAME:-eks-multitenant}"
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_PROFILE="${AWS_PROFILE:-default}"
VPC_ID="${VPC_ID:-}"
SUBNET1="${SUBNET1:-}"
SUBNET2="${SUBNET2:-}"
SUBNET3="${SUBNET3:-}"
SKIP_CFN=false
SKIP_K8S=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CFN_TEMPLATE="${REPO_ROOT}/cfn/main.yaml"
MODULES_DIR="${REPO_ROOT}/modules"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack-name) STACK_NAME="$2"; shift 2 ;;
    --region)     AWS_REGION="$2"; shift 2 ;;
    --profile)    AWS_PROFILE="$2"; shift 2 ;;
    --vpc-id)     VPC_ID="$2"; shift 2 ;;
    --subnet1)    SUBNET1="$2"; shift 2 ;;
    --subnet2)    SUBNET2="$2"; shift 2 ;;
    --subnet3)    SUBNET3="$2"; shift 2 ;;
    --k8s-only)   SKIP_CFN=true; shift ;;
    --cfn-only)   SKIP_K8S=true; shift ;;
    --help)
      sed -n '/^# Usage/,/^[^#]/{ /^[^#]/d; s/^# \{0,3\}//; p }' "$0"
      exit 0
      ;;
    *) echo "[ERROR] Unknown flag: $1"; exit 1 ;;
  esac
done

AWS_OPTS="--region ${AWS_REGION} --profile ${AWS_PROFILE}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
ok()   { echo "[$(date '+%H:%M:%S')] ✓ $*"; }
warn() { echo "[$(date '+%H:%M:%S')] ⚠  $*"; }
fail() { echo "[$(date '+%H:%M:%S')] ✗ $*" >&2; exit 1; }

require_tool() {
  command -v "$1" &>/dev/null || fail "Required tool not found: $1. Install it and re-run."
}

cfn_output() {
  local key="$1"
  aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue" \
    --output text \
    ${AWS_OPTS}
}

wait_for_nodes() {
  local min_ready="${1:-1}"
  local max_wait=300
  local elapsed=0
  log "Waiting for at least ${min_ready} node(s) to be Ready (timeout ${max_wait}s)..."
  while true; do
    local ready
    ready=$(kubectl get nodes --no-headers 2>/dev/null \
      | grep -c " Ready " || true)
    if [[ "${ready}" -ge "${min_ready}" ]]; then
      ok "${ready} node(s) Ready"
      return 0
    fi
    if [[ "${elapsed}" -ge "${max_wait}" ]]; then
      warn "Timed out waiting for nodes. The ASG may still be scaling up."
      warn "Re-run with --k8s-only once nodes are Ready."
      return 1
    fi
    sleep 15
    elapsed=$((elapsed + 15))
    log "  ${ready}/${min_ready} nodes Ready (${elapsed}s elapsed)..."
  done
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
log "Checking required tools..."
require_tool aws
require_tool kubectl
require_tool jq

aws sts get-caller-identity ${AWS_OPTS} &>/dev/null \
  || fail "AWS credentials not configured for profile '${AWS_PROFILE}'"
ok "AWS credentials verified"

# ---------------------------------------------------------------------------
# Step 1: Deploy CloudFormation
# ---------------------------------------------------------------------------
deploy_cfn() {
  # Build override list — only include subnet/VPC params when provided so
  # that subsequent runs (--k8s-only or re-deploys) can omit them and
  # CloudFormation will use the previous values via UsePreviousValue.
  local overrides="ClusterName=${STACK_NAME} EnableCustomer1=true EnableCustomer2=false EnableCustomer3=false"

  if [[ -n "${VPC_ID}" ]];  then overrides="${overrides} VpcId=${VPC_ID}"; fi
  if [[ -n "${SUBNET1}" ]]; then overrides="${overrides} PrivateSubnet1Id=${SUBNET1}"; fi
  if [[ -n "${SUBNET2}" ]]; then overrides="${overrides} PrivateSubnet2Id=${SUBNET2}"; fi
  if [[ -n "${SUBNET3}" ]]; then overrides="${overrides} PrivateSubnet3Id=${SUBNET3}"; fi

  log "Deploying CloudFormation stack '${STACK_NAME}'..."

  # shellcheck disable=SC2086
  aws cloudformation deploy \
    --stack-name "${STACK_NAME}" \
    --template-file "${CFN_TEMPLATE}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides ${overrides} \
    ${AWS_OPTS} \
    || fail "CloudFormation deploy failed. Check the AWS Console Events tab for details."

  ok "CloudFormation stack deployed"
}

# ---------------------------------------------------------------------------
# Step 2: Update kubeconfig
# ---------------------------------------------------------------------------
update_kubeconfig() {
  local cluster_name
  cluster_name="$(cfn_output ClusterName)"
  [[ -z "${cluster_name}" ]] && fail "Could not read ClusterName from CFN outputs"

  log "Updating kubeconfig for cluster '${cluster_name}'..."
  aws eks update-kubeconfig \
    --name "${cluster_name}" \
    --region "${AWS_REGION}" \
    --profile "${AWS_PROFILE}"

  # Verify connectivity — will fail if running outside the VPC
  if ! kubectl cluster-info --request-timeout=10s &>/dev/null; then
    warn "kubectl cannot reach the private EKS endpoint."
    warn "Ensure you are connected to the VPC via VPN, Direct Connect,"
    warn "or use SSM Session Manager to port-forward through a bastion:"
    warn "  aws ssm start-session --target <bastion-instance-id> \\"
    warn "    --document-name AWS-StartPortForwardingSession \\"
    warn "    --parameters '{\"portNumber\":[\"443\"],\"localPortNumber\":[\"8443\"]}'"
    fail "No network path to the cluster private endpoint."
  fi
  ok "kubeconfig updated — cluster is reachable"
}

# ---------------------------------------------------------------------------
# Step 3: Apply kubectl manifests in dependency order
# ---------------------------------------------------------------------------
apply_manifests() {
  log "Applying Kubernetes manifests..."

  # 1. Namespaces — everything else is namespace-scoped
  log "  → namespaces"
  kubectl apply -f "${MODULES_DIR}/namespaces/namespaces.yaml"

  # 2. BRUPOP — CRDs must be established before RBAC and operator pods
  log "  → brupop namespace"
  kubectl apply -f "${MODULES_DIR}/brupop/00-namespace.yaml"

  log "  → brupop CRDs"
  kubectl apply -f "${MODULES_DIR}/brupop/01-crds.yaml"

  log "  → waiting for BottlerocketShadow CRD to be established..."
  kubectl wait --for=condition=Established \
    crd/bottlerocketshadows.brupop.bottlerocket.aws \
    --timeout=60s

  log "  → brupop RBAC"
  kubectl apply -f "${MODULES_DIR}/brupop/02-rbac.yaml"

  log "  → brupop controller"
  kubectl apply -f "${MODULES_DIR}/brupop/03-controller.yaml"

  log "  → brupop agent DaemonSet"
  kubectl apply -f "${MODULES_DIR}/brupop/04-agent.yaml"

  # 3. Tenant RBAC
  log "  → cluster roles"
  kubectl apply -f "${MODULES_DIR}/rbac/cluster-roles.yaml"

  log "  → tenant role bindings"
  kubectl apply -f "${MODULES_DIR}/rbac/role-bindings.yaml"

  # 4. Network isolation policies
  log "  → network policies"
  kubectl apply -f "${MODULES_DIR}/network-policies/isolation.yaml"

  # 5. Resource quotas
  log "  → resource quotas"
  kubectl apply -f "${MODULES_DIR}/resource-quotas/quotas.yaml"

  ok "All manifests applied"
}

# ---------------------------------------------------------------------------
# Step 4: Deploy sample nginx app (skipped until ECR URI is filled in)
# ---------------------------------------------------------------------------
deploy_nginx() {
  local manifest="${MODULES_DIR}/nginx/deployment.yaml"

  if grep -q "REPLACE_WITH_YOUR_ECR_ACCOUNT_ID" "${manifest}"; then
    log "Skipping nginx sample — update the image URI in modules/nginx/deployment.yaml first"
    return
  fi

  log "Deploying nginx sample application..."
  kubectl apply -f "${manifest}"
  kubectl rollout status deployment/nginx \
    --namespace tenant-customer1 \
    --timeout=120s \
    && ok "nginx deployment is ready"
}

# ---------------------------------------------------------------------------
# Step 5: Print summary + BYOC bootstrap template
# ---------------------------------------------------------------------------
print_summary() {
  local cluster_name endpoint ca_data node_role_arn
  cluster_name="$(cfn_output ClusterName)"
  endpoint="$(cfn_output ClusterEndpoint)"
  ca_data="$(cfn_output ClusterCertificateAuthority)"
  node_role_arn="$(cfn_output NodeGroupRoleArn)"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " Deployment complete"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " Cluster:    ${cluster_name}"
  echo " Endpoint:   ${endpoint}  (private only)"
  echo " Region:     ${AWS_REGION}"
  echo ""
  echo " Node status:"
  kubectl get nodes -L node-role,customer-id --no-headers 2>/dev/null \
    | awk '{printf "   %-50s role=%-10s customer=%s\n", $1, $7, $8}' || true
  echo ""
  echo " Tenant namespaces:"
  kubectl get namespaces -l isolation=strict --no-headers 2>/dev/null \
    | awk '{print "   " $1}' || true
  echo ""
  echo " BRUPOP pods:"
  kubectl get pods -n brupop-bottlerocket-aws --no-headers 2>/dev/null \
    | awk '{printf "   %-45s %s\n", $1, $3}' || true
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo " To onboard a new customer:"
  echo "   1. Set EnableCustomer2=true (and optionally Customer2IAMRoleArn)"
  echo "   2. Re-run: ./scripts/deploy.sh --stack-name ${STACK_NAME}"
  echo ""
  echo " ── Bring Your Own Compute (BYOC) ───────────────────────────"
  echo ""
  echo " A customer can self-register any Bottlerocket EC2 instance by"
  echo " using the following user-data. The instance MUST use the IAM"
  echo " instance profile: ${node_role_arn}"
  echo ""
  echo " ┌─ /etc/userdata (Bottlerocket TOML) ──────────────────────"
  echo " │"
  echo " │  [settings.kubernetes]"
  echo " │  api-server         = \"${endpoint}\""
  echo " │  cluster-name       = \"${cluster_name}\""
  echo " │  cluster-certificate = \"${ca_data}\""
  echo " │"
  echo " │  [settings.kubernetes.node-labels]"
  echo " │  \"node-role\"       = \"customer\""
  echo " │  \"nodegroup-type\"  = \"customer\""
  echo " │  \"customer-id\"     = \"<CUSTOMER_NAME>\""
  echo " │  \"bottlerocket.aws/updater-interface-version\" = \"2.0.0\""
  echo " │"
  echo " │  [settings.kubernetes.node-taints]"
  echo " │  \"customer-id\" = \"<CUSTOMER_NAME>:NoSchedule\""
  echo " │"
  echo " └───────────────────────────────────────────────────────────"
  echo ""
  echo " Replace <CUSTOMER_NAME> with the tenant name (e.g. customer1)."
  echo " Pods must declare the matching toleration and nodeAffinity to"
  echo " land on BYOC nodes — see modules/nginx/deployment.yaml for an"
  echo " example."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  echo ""
  log "Starting EKS multi-tenant deployment"
  log "  Stack:   ${STACK_NAME}"
  log "  Region:  ${AWS_REGION}"
  log "  Profile: ${AWS_PROFILE}"
  [[ -n "${VPC_ID}" ]]  && log "  VPC:     ${VPC_ID}"
  [[ -n "${SUBNET1}" ]] && log "  Subnets: ${SUBNET1}, ${SUBNET2}, ${SUBNET3}"
  echo ""

  if [[ "${SKIP_CFN}" == false ]]; then
    [[ -z "${VPC_ID}" || -z "${SUBNET1}" || -z "${SUBNET2}" || -z "${SUBNET3}" ]] && {
      # If the stack already exists we can skip these — CFN will use existing values.
      if ! aws cloudformation describe-stacks --stack-name "${STACK_NAME}" ${AWS_OPTS} &>/dev/null; then
        fail "First deploy requires --vpc-id, --subnet1, --subnet2, --subnet3"
      fi
      warn "VPC/subnet args not provided — reusing existing stack parameter values"
    }
    deploy_cfn
  fi

  update_kubeconfig

  if [[ "${SKIP_K8S}" == false ]]; then
    # Wait for at least one system node before applying workload manifests.
    # BRUPOP controller won't schedule until a node with node-role=system is Ready.
    wait_for_nodes 1 || true
    apply_manifests
    deploy_nginx
  fi

  print_summary
}

main "$@"
