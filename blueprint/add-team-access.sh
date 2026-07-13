#!/bin/bash
set -e

# =============================================================================
# Add Team Access to a Blueprint Cluster
#
# Creates a namespace for the team and grants them namespace-scoped admin.
# Teams CANNOT modify system namespaces or critical addons.
#
# Usage:
#   ./add-team-access.sh \
#     --cluster-name my-cluster \
#     --team-name payments \
#     --team-role-arn arn:aws:iam::123456789012:role/TeamPayments \
#     --region us-east-1 \
#     --profile my-aws-profile
# =============================================================================

while [[ $# -gt 0 ]]; do
  case $1 in
    --cluster-name) CLUSTER_NAME="$2"; shift 2;;
    --team-name) TEAM_NAME="$2"; shift 2;;
    --team-role-arn) TEAM_ROLE_ARN="$2"; shift 2;;
    --region) REGION="$2"; shift 2;;
    --profile) PROFILE="$2"; shift 2;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

REGION="${REGION:-us-east-1}"
PROFILE_ARG=""
if [ -n "$PROFILE" ]; then
  PROFILE_ARG="--profile $PROFILE"
fi

if [ -z "$CLUSTER_NAME" ] || [ -z "$TEAM_NAME" ] || [ -z "$TEAM_ROLE_ARN" ]; then
  echo "ERROR: Required: --cluster-name, --team-name, --team-role-arn"
  exit 1
fi

NAMESPACE="team-${TEAM_NAME}"

echo "Adding team access:"
echo "  Cluster:   $CLUSTER_NAME"
echo "  Team:      $TEAM_NAME"
echo "  Namespace: $NAMESPACE"
echo "  Role ARN:  $TEAM_ROLE_ARN"
echo ""

# Step 1: Create namespace
echo "[1/3] Creating namespace ${NAMESPACE}..."
kubectl create namespace "$NAMESPACE" 2>/dev/null || echo "  Namespace already exists"

kubectl label namespace "$NAMESPACE" \
  team="$TEAM_NAME" \
  managed-by=eks-blueprint \
  --overwrite

# Step 2: Create EKS access entry with namespace-scoped access
echo "[2/3] Creating EKS access entry..."
aws eks create-access-entry \
  --cluster-name "$CLUSTER_NAME" \
  --principal-arn "$TEAM_ROLE_ARN" \
  --type STANDARD \
  --region "$REGION" \
  $PROFILE_ARG 2>/dev/null || echo "  Access entry already exists"

# Namespace-scoped admin - team can do anything IN their namespace
# but cannot touch other namespaces or cluster-level resources
aws eks associate-access-policy \
  --cluster-name "$CLUSTER_NAME" \
  --principal-arn "$TEAM_ROLE_ARN" \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy \
  --access-scope "type=namespace,namespaces=${NAMESPACE}" \
  --region "$REGION" \
  $PROFILE_ARG

echo ""

# Step 3: Apply resource quota
echo "[3/3] Applying resource quota..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ${TEAM_NAME}-quota
  namespace: ${NAMESPACE}
spec:
  hard:
    requests.cpu: "8"
    requests.memory: 16Gi
    limits.cpu: "16"
    limits.memory: 32Gi
    pods: "50"
    services.loadbalancers: "5"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: ${TEAM_NAME}-limits
  namespace: ${NAMESPACE}
spec:
  limits:
    - default:
        cpu: 500m
        memory: 512Mi
      defaultRequest:
        cpu: 100m
        memory: 128Mi
      type: Container
EOF

echo ""
echo "Done. Team '$TEAM_NAME' can now access namespace '$NAMESPACE' using:"
echo "  aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION"
echo "  kubectl get pods -n $NAMESPACE"
echo ""
echo "They CANNOT:"
echo "  - Access kube-system, logging, networking, kyverno, monitoring namespaces"
echo "  - Delete or modify critical addons"
echo "  - Create cluster-level resources (ClusterRole, etc.)"
echo ""
