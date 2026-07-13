#!/bin/bash
set -e

# =============================================================================
# EKS Blueprint Deployment Script
#
# Deploys a fully configured EKS cluster with:
#   - Managed node group
#   - Kyverno (policy engine)
#   - AWS Load Balancer Controller
#   - FluentBit (logging to CloudWatch)
#   - Metrics Server
#   - Protection policies (prevent addon deletion)
#
# Usage:
#   ./deploy-blueprint.sh \
#     --cluster-name my-cluster \
#     --vpc-id vpc-xxx \
#     --subnet-1 subnet-xxx \
#     --subnet-2 subnet-xxx \
#     --subnet-3 subnet-xxx \
#     --region us-east-1 \
#     --profile my-aws-profile \
#     --environment prod
# =============================================================================

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --cluster-name) CLUSTER_NAME="$2"; shift 2;;
    --vpc-id) VPC_ID="$2"; shift 2;;
    --subnet-1) SUBNET_1="$2"; shift 2;;
    --subnet-2) SUBNET_2="$2"; shift 2;;
    --subnet-3) SUBNET_3="$2"; shift 2;;
    --region) REGION="$2"; shift 2;;
    --profile) PROFILE="$2"; shift 2;;
    --environment) ENVIRONMENT="$2"; shift 2;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

# Defaults
REGION="${REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-prod}"
PROFILE_ARG=""
if [ -n "$PROFILE" ]; then
  PROFILE_ARG="--profile $PROFILE"
fi

# Validation
if [ -z "$CLUSTER_NAME" ] || [ -z "$VPC_ID" ] || [ -z "$SUBNET_1" ] || [ -z "$SUBNET_2" ] || [ -z "$SUBNET_3" ]; then
  echo "ERROR: Required parameters: --cluster-name, --vpc-id, --subnet-1, --subnet-2, --subnet-3"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "============================================"
echo "EKS Blueprint Deployment"
echo "============================================"
echo "  Cluster:     $CLUSTER_NAME"
echo "  VPC:         $VPC_ID"
echo "  Region:      $REGION"
echo "  Environment: $ENVIRONMENT"
echo "============================================"
echo ""

# -------------------------------------------------------------------------
# Step 1: Deploy CloudFormation Stack
# -------------------------------------------------------------------------
echo "[1/7] Deploying CloudFormation stack..."

aws cloudformation create-stack \
  --stack-name "${CLUSTER_NAME}-blueprint" \
  --template-body "file://${SCRIPT_DIR}/cfn-eks-blueprint.yaml" \
  --parameters \
    ParameterKey=ClusterName,ParameterValue="${CLUSTER_NAME}" \
    ParameterKey=VpcId,ParameterValue="${VPC_ID}" \
    ParameterKey=Subnet1Id,ParameterValue="${SUBNET_1}" \
    ParameterKey=Subnet2Id,ParameterValue="${SUBNET_2}" \
    ParameterKey=Subnet3Id,ParameterValue="${SUBNET_3}" \
    ParameterKey=Environment,ParameterValue="${ENVIRONMENT}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$REGION" \
  $PROFILE_ARG

echo "  Waiting for stack creation (~15 minutes)..."
aws cloudformation wait stack-create-complete \
  --stack-name "${CLUSTER_NAME}-blueprint" \
  --region "$REGION" \
  $PROFILE_ARG

echo "  Stack created."
echo ""

# -------------------------------------------------------------------------
# Step 2: Configure kubectl
# -------------------------------------------------------------------------
echo "[2/7] Configuring kubectl..."

aws eks update-kubeconfig \
  --name "$CLUSTER_NAME" \
  --region "$REGION" \
  $PROFILE_ARG

kubectl get nodes
echo ""

# -------------------------------------------------------------------------
# Step 3: Install Kyverno (policy engine - must be first)
# -------------------------------------------------------------------------
echo "[3/7] Installing Kyverno..."

helm repo add kyverno https://kyverno.github.io/kyverno 2>/dev/null || true
helm repo update

helm install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace \
  --set replicaCount=3 \
  --set admissionController.replicas=3 \
  --wait --timeout 5m

echo "  Kyverno installed."
echo ""

# -------------------------------------------------------------------------
# Step 4: Install ArgoCD (GitOps controller)
# -------------------------------------------------------------------------
echo "[4/7] Installing ArgoCD..."

helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --set 'configs.params.server\.insecure=true' \
  --set controller.replicas=2 \
  --set server.replicas=2 \
  --set repoServer.replicas=2 \
  --wait --timeout 5m

echo "  ArgoCD installed."
echo ""

# Apply ArgoCD projects (platform + teams)
kubectl apply -f "${SCRIPT_DIR}/addons/argocd/project.yaml"
echo "  ArgoCD projects configured."
echo ""

# -------------------------------------------------------------------------
# Step 5: Deploy critical addons
# -------------------------------------------------------------------------
echo "[5/7] Installing critical addons..."

# AWS Load Balancer Controller
echo "  Installing AWS Load Balancer Controller..."
helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set region="$REGION" \
  --set vpcId="$VPC_ID" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set replicaCount=2 \
  --wait --timeout 5m

# Metrics Server
echo "  Installing Metrics Server..."
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server 2>/dev/null || true
helm install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --set replicas=2 \
  --wait --timeout 5m

echo "  All addons installed."
echo "  (CloudWatch Observability Agent deployed as EKS addon via CloudFormation)"
echo ""

# -------------------------------------------------------------------------
# Step 6: Apply protection policies
# -------------------------------------------------------------------------
echo "[6/7] Applying Kyverno protection policies..."

kubectl apply -f "${SCRIPT_DIR}/policies/"

echo "  Policies applied."
echo ""

# -------------------------------------------------------------------------
# Step 7: Configure ArgoCD self-management (app-of-apps)
# -------------------------------------------------------------------------
echo "[7/7] Configuring ArgoCD app-of-apps..."

kubectl apply -f "${SCRIPT_DIR}/addons/argocd/apps.yaml"

echo "  ArgoCD will now manage all addons and policies from Git."
echo "  Update the repoURL in addons/argocd/apps.yaml to point to your repo."
echo ""

# -------------------------------------------------------------------------
# Verification
# -------------------------------------------------------------------------
echo "============================================"
echo "VERIFICATION"
echo "============================================"

echo ""
echo "Nodes:"
kubectl get nodes

echo ""
echo "Critical addons:"
kubectl get pods -n kyverno
kubectl get pods -n argocd
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
kubectl get pods -n amazon-cloudwatch
kubectl get pods -n kube-system -l app.kubernetes.io/name=metrics-server

echo ""
echo "Kyverno policies:"
kubectl get clusterpolicies

echo ""
echo "ArgoCD applications:"
kubectl get applications -n argocd

echo ""
echo "============================================"
echo "DEPLOYMENT COMPLETE"
echo "============================================"
echo ""
echo "Protection verification - try deleting a critical addon (should fail):"
echo "  kubectl delete deployment -n kyverno kyverno-admission-controller"
echo "  kubectl delete deployment -n argocd argocd-server"
echo ""
echo "ArgoCD UI:"
echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "  Open: https://localhost:8080"
echo "  Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "To import into Rancher (optional - for visibility):"
echo "  1. In Rancher UI: Cluster Management > Import Existing > Generic"
echo "  2. Run the generated kubectl apply command against this cluster"
echo ""
echo "To onboard a team:"
echo "  ./add-team-access.sh --cluster-name $CLUSTER_NAME --team-name <name> --team-role-arn <arn>"
echo ""
