#!/bin/bash
set -e

echo "=========================================="
echo "Cross-Account EKS Deployment"
echo "=========================================="
echo ""

# Load configuration
if [ -f /tmp/eks-deployment-config.env ]; then
    source /tmp/eks-deployment-config.env
    echo "✓ Loaded configuration"
else
    echo "❌ Please run setup-aws-profiles.sh and gather-vpc-info.sh first"
    exit 1
fi

# Verify all required variables are set
required_vars=(
    "HUB_ACCOUNT_ID" "SPOKE_ACCOUNT_ID" "AWS_REGION"
    "HUB_VPC_ID" "HUB_SUBNET1" "HUB_SUBNET2" "HUB_SUBNET3"
    "SPOKE_VPC_ID" "SPOKE_SUBNET1" "SPOKE_SUBNET2" "SPOKE_SUBNET3"
)

for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo "❌ Missing required variable: $var"
        exit 1
    fi
done

echo ""
echo "Configuration:"
echo "  Hub Account: ${HUB_ACCOUNT_ID}"
echo "  Spoke Account: ${SPOKE_ACCOUNT_ID}"
echo "  Region: ${AWS_REGION}"
echo ""

# ========================================
# STEP 1: Deploy Hub Cluster
# ========================================

echo "=========================================="
echo "STEP 1: Deploying Hub Cluster"
echo "=========================================="
echo ""

aws cloudformation create-stack \
  --stack-name hub-eks-cluster \
  --template-body file://cfn/hub-cluster-with-cross-account-nodes.yaml \
  --parameters \
    ParameterKey=ClusterName,ParameterValue=hub-shared-cluster \
    ParameterKey=KubernetesVersion,ParameterValue=1.32 \
    ParameterKey=VpcId,ParameterValue=${HUB_VPC_ID} \
    ParameterKey=Subnet1Id,ParameterValue=${HUB_SUBNET1} \
    ParameterKey=Subnet2Id,ParameterValue=${HUB_SUBNET2} \
    ParameterKey=Subnet3Id,ParameterValue=${HUB_SUBNET3} \
    ParameterKey=SpokeAccount1Id,ParameterValue=${SPOKE_ACCOUNT_ID} \
  --capabilities CAPABILITY_NAMED_IAM \
  --region ${AWS_REGION} \
  --profile hub

echo "✓ Hub cluster stack creation initiated"
echo "  Waiting for stack to complete (this takes ~15 minutes)..."
echo ""

aws cloudformation wait stack-create-complete \
  --stack-name hub-eks-cluster \
  --region ${AWS_REGION} \
  --profile hub

echo "✓ Hub cluster deployed successfully!"
echo ""

# Get hub cluster outputs
echo "Retrieving hub cluster details..."
HUB_CLUSTER_NAME=$(aws cloudformation describe-stacks \
  --stack-name hub-eks-cluster \
  --query 'Stacks[0].Outputs[?OutputKey==`ClusterName`].OutputValue' \
  --output text \
  --region ${AWS_REGION} \
  --profile hub)

HUB_CLUSTER_ENDPOINT=$(aws cloudformation describe-stacks \
  --stack-name hub-eks-cluster \
  --query 'Stacks[0].Outputs[?OutputKey==`ClusterEndpoint`].OutputValue' \
  --output text \
  --region ${AWS_REGION} \
  --profile hub)

HUB_CLUSTER_CA=$(aws cloudformation describe-stacks \
  --stack-name hub-eks-cluster \
  --query 'Stacks[0].Outputs[?OutputKey==`ClusterCA`].OutputValue' \
  --output text \
  --region ${AWS_REGION} \
  --profile hub)

HUB_CLUSTER_SG=$(aws cloudformation describe-stacks \
  --stack-name hub-eks-cluster \
  --query 'Stacks[0].Outputs[?OutputKey==`ClusterSecurityGroupId`].OutputValue' \
  --output text \
  --region ${AWS_REGION} \
  --profile hub)

echo "  Cluster Name: ${HUB_CLUSTER_NAME}"
echo "  Endpoint: ${HUB_CLUSTER_ENDPOINT}"
echo "  Security Group: ${HUB_CLUSTER_SG}"
echo ""

# Configure kubectl
echo "Configuring kubectl..."
aws eks update-kubeconfig \
  --name ${HUB_CLUSTER_NAME} \
  --region ${AWS_REGION} \
  --profile hub

echo "✓ kubectl configured"
echo ""

# Verify cluster access
echo "Verifying cluster access..."
kubectl get svc
echo ""

# ========================================
# STEP 2: Deploy Spoke Nodegroup
# ========================================

echo "=========================================="
echo "STEP 2: Deploying Spoke Nodegroup"
echo "=========================================="
echo ""

aws cloudformation create-stack \
  --stack-name spoke-customer1-nodes \
  --template-body file://cfn/spoke-nodegroup-only.yaml \
  --parameters \
    ParameterKey=HubAccountId,ParameterValue=${HUB_ACCOUNT_ID} \
    ParameterKey=HubClusterName,ParameterValue=${HUB_CLUSTER_NAME} \
    ParameterKey=HubClusterEndpoint,ParameterValue=${HUB_CLUSTER_ENDPOINT} \
    ParameterKey=HubClusterCA,ParameterValue=${HUB_CLUSTER_CA} \
    ParameterKey=HubClusterSecurityGroupId,ParameterValue=${HUB_CLUSTER_SG} \
    ParameterKey=NodeGroupName,ParameterValue=customer1-nodes \
    ParameterKey=CustomerName,ParameterValue=customer1 \
    ParameterKey=VpcId,ParameterValue=${SPOKE_VPC_ID} \
    ParameterKey=Subnet1Id,ParameterValue=${SPOKE_SUBNET1} \
    ParameterKey=Subnet2Id,ParameterValue=${SPOKE_SUBNET2} \
    ParameterKey=Subnet3Id,ParameterValue=${SPOKE_SUBNET3} \
    ParameterKey=HubECRRegion,ParameterValue=${AWS_REGION} \
  --capabilities CAPABILITY_NAMED_IAM \
  --region ${AWS_REGION} \
  --profile spoke1

echo "✓ Spoke nodegroup stack creation initiated"
echo "  Waiting for stack to complete (this takes ~5-10 minutes)..."
echo ""

aws cloudformation wait stack-create-complete \
  --stack-name spoke-customer1-nodes \
  --region ${AWS_REGION} \
  --profile spoke1

echo "✓ Spoke nodegroup deployed successfully!"
echo ""

# Get spoke node role ARN
echo "Retrieving spoke node role..."
SPOKE_NODE_ROLE=$(aws cloudformation describe-stacks \
  --stack-name spoke-customer1-nodes \
  --query 'Stacks[0].Outputs[?OutputKey==`NodeRoleArn`].OutputValue' \
  --output text \
  --region ${AWS_REGION} \
  --profile spoke1)

echo "  Node Role ARN: ${SPOKE_NODE_ROLE}"
echo ""

# ========================================
# STEP 3: Create Access Entry
# ========================================

echo "=========================================="
echo "STEP 3: Creating EKS Access Entry"
echo "=========================================="
echo ""

echo "Creating access entry for spoke node role..."
aws eks create-access-entry \
  --cluster-name ${HUB_CLUSTER_NAME} \
  --principal-arn ${SPOKE_NODE_ROLE} \
  --type EC2_LINUX \
  --region ${AWS_REGION} \
  --profile hub

echo "✓ Access entry created"
echo ""

echo "Associating worker node policy..."
aws eks associate-access-policy-association \
  --cluster-name ${HUB_CLUSTER_NAME} \
  --principal-arn ${SPOKE_NODE_ROLE} \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSWorkerNodePolicy \
  --access-scope type=cluster \
  --region ${AWS_REGION} \
  --profile hub

echo "✓ Policy associated"
echo ""

# ========================================
# STEP 4: Verify Deployment
# ========================================

echo "=========================================="
echo "STEP 4: Verifying Deployment"
echo "=========================================="
echo ""

echo "Waiting for nodes to join cluster (this may take 2-3 minutes)..."
sleep 120

echo ""
echo "Current nodes in cluster:"
kubectl get nodes -o wide

echo ""
echo "Nodes with customer1 label:"
kubectl get nodes --selector=customer=customer1 -o wide

echo ""
echo "=========================================="
echo "✓ DEPLOYMENT COMPLETE!"
echo "=========================================="
echo ""
echo "Summary:"
echo "--------"
echo "Hub Cluster: ${HUB_CLUSTER_NAME}"
echo "Hub Account: ${HUB_ACCOUNT_ID}"
echo "Spoke Account: ${SPOKE_ACCOUNT_ID}"
echo "Node Role: ${SPOKE_NODE_ROLE}"
echo ""
echo "Next Steps:"
echo "1. Deploy test workload: kubectl apply -f test-deployment.yaml"
echo "2. Add more spoke accounts: Repeat Step 2-3 with different spoke accounts"
echo "3. Configure ECR cross-account access for shared images"
echo ""

# Save deployment info
cat > /tmp/eks-deployment-info.txt << EOF
Deployment Information
======================
Hub Cluster Name: ${HUB_CLUSTER_NAME}
Hub Cluster Endpoint: ${HUB_CLUSTER_ENDPOINT}
Hub Security Group: ${HUB_CLUSTER_SG}
Hub Account ID: ${HUB_ACCOUNT_ID}
Spoke Account ID: ${SPOKE_ACCOUNT_ID}
Spoke Node Role: ${SPOKE_NODE_ROLE}
Region: ${AWS_REGION}

kubectl config current-context: $(kubectl config current-context)
EOF

echo "✓ Deployment info saved to /tmp/eks-deployment-info.txt"
echo ""
