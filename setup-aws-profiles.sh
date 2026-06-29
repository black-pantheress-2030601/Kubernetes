#!/bin/bash
set -e

echo "=========================================="
echo "AWS CLI Profile Setup for Cross-Account EKS"
echo "=========================================="
echo ""

# Hub Account Configuration
echo "HUB ACCOUNT CONFIGURATION"
echo "-------------------------"
read -p "Enter Hub Account ID: " HUB_ACCOUNT_ID
read -p "Enter Hub Account AWS Access Key ID: " HUB_ACCESS_KEY
read -sp "Enter Hub Account AWS Secret Access Key: " HUB_SECRET_KEY
echo ""
read -p "Enter Hub Account AWS Region [ap-southeast-2]: " HUB_REGION
HUB_REGION=${HUB_REGION:-ap-southeast-2}

# Configure hub profile
aws configure set aws_access_key_id "$HUB_ACCESS_KEY" --profile hub
aws configure set aws_secret_access_key "$HUB_SECRET_KEY" --profile hub
aws configure set region "$HUB_REGION" --profile hub
aws configure set output json --profile hub

echo ""
echo "✓ Hub profile configured"
echo ""

# Spoke Account Configuration
echo "SPOKE ACCOUNT CONFIGURATION"
echo "----------------------------"
read -p "Enter Spoke Account ID: " SPOKE_ACCOUNT_ID
read -p "Enter Spoke Account AWS Access Key ID: " SPOKE_ACCESS_KEY
read -sp "Enter Spoke Account AWS Secret Access Key: " SPOKE_SECRET_KEY
echo ""
read -p "Enter Spoke Account AWS Region [ap-southeast-2]: " SPOKE_REGION
SPOKE_REGION=${SPOKE_REGION:-ap-southeast-2}

# Configure spoke profile
aws configure set aws_access_key_id "$SPOKE_ACCESS_KEY" --profile spoke1
aws configure set aws_secret_access_key "$SPOKE_SECRET_KEY" --profile spoke1
aws configure set region "$SPOKE_REGION" --profile spoke1
aws configure set output json --profile spoke1

echo ""
echo "✓ Spoke profile configured"
echo ""

# Verify profiles
echo "=========================================="
echo "VERIFYING PROFILES"
echo "=========================================="
echo ""

echo "Hub Account Identity:"
aws sts get-caller-identity --profile hub
echo ""

echo "Spoke Account Identity:"
aws sts get-caller-identity --profile spoke1
echo ""

# Save account IDs to file for later use
cat > /tmp/eks-deployment-config.env << EOF
export HUB_ACCOUNT_ID="$HUB_ACCOUNT_ID"
export SPOKE_ACCOUNT_ID="$SPOKE_ACCOUNT_ID"
export AWS_REGION="$HUB_REGION"
EOF

echo "=========================================="
echo "✓ Configuration saved to /tmp/eks-deployment-config.env"
echo "=========================================="
echo ""
echo "Next steps:"
echo "1. Run: source /tmp/eks-deployment-config.env"
echo "2. Provide VPC and subnet IDs from both accounts"
echo ""
