#!/bin/bash
set -e

echo "=========================================="
echo "Gathering VPC and Subnet Information"
echo "=========================================="
echo ""

# Source the config
if [ -f /tmp/eks-deployment-config.env ]; then
    source /tmp/eks-deployment-config.env
    echo "✓ Loaded account configuration"
else
    echo "❌ Please run setup-aws-profiles.sh first"
    exit 1
fi

echo ""
echo "HUB ACCOUNT VPCs (${HUB_ACCOUNT_ID})"
echo "======================================"
aws ec2 describe-vpcs --profile hub --query 'Vpcs[*].[VpcId,CidrBlock,Tags[?Key==`Name`].Value|[0]]' --output table

echo ""
read -p "Enter Hub VPC ID: " HUB_VPC_ID

echo ""
echo "Subnets in Hub VPC ${HUB_VPC_ID}:"
aws ec2 describe-subnets --profile hub \
  --filters "Name=vpc-id,Values=${HUB_VPC_ID}" \
  --query 'Subnets[*].[SubnetId,AvailabilityZone,CidrBlock,Tags[?Key==`Name`].Value|[0]]' \
  --output table

echo ""
echo "Select 3 subnets (preferably in different AZs):"
read -p "Hub Subnet 1 ID: " HUB_SUBNET1
read -p "Hub Subnet 2 ID: " HUB_SUBNET2
read -p "Hub Subnet 3 ID: " HUB_SUBNET3

echo ""
echo "SPOKE ACCOUNT VPCs (${SPOKE_ACCOUNT_ID})"
echo "=========================================="
aws ec2 describe-vpcs --profile spoke1 --query 'Vpcs[*].[VpcId,CidrBlock,Tags[?Key==`Name`].Value|[0]]' --output table

echo ""
read -p "Enter Spoke VPC ID: " SPOKE_VPC_ID

echo ""
echo "Subnets in Spoke VPC ${SPOKE_VPC_ID}:"
aws ec2 describe-subnets --profile spoke1 \
  --filters "Name=vpc-id,Values=${SPOKE_VPC_ID}" \
  --query 'Subnets[*].[SubnetId,AvailabilityZone,CidrBlock,Tags[?Key==`Name`].Value|[0]]' \
  --output table

echo ""
echo "Select 3 subnets (preferably in different AZs):"
read -p "Spoke Subnet 1 ID: " SPOKE_SUBNET1
read -p "Spoke Subnet 2 ID: " SPOKE_SUBNET2
read -p "Spoke Subnet 3 ID: " SPOKE_SUBNET3

# Append to config file
cat >> /tmp/eks-deployment-config.env << EOF
export HUB_VPC_ID="$HUB_VPC_ID"
export HUB_SUBNET1="$HUB_SUBNET1"
export HUB_SUBNET2="$HUB_SUBNET2"
export HUB_SUBNET3="$HUB_SUBNET3"
export SPOKE_VPC_ID="$SPOKE_VPC_ID"
export SPOKE_SUBNET1="$SPOKE_SUBNET1"
export SPOKE_SUBNET2="$SPOKE_SUBNET2"
export SPOKE_SUBNET3="$SPOKE_SUBNET3"
EOF

echo ""
echo "=========================================="
echo "✓ VPC Configuration saved"
echo "=========================================="
echo ""
echo "Configuration Summary:"
echo "---------------------"
source /tmp/eks-deployment-config.env
echo "Hub Account: ${HUB_ACCOUNT_ID}"
echo "Hub VPC: ${HUB_VPC_ID}"
echo "Hub Subnets: ${HUB_SUBNET1}, ${HUB_SUBNET2}, ${HUB_SUBNET3}"
echo ""
echo "Spoke Account: ${SPOKE_ACCOUNT_ID}"
echo "Spoke VPC: ${SPOKE_VPC_ID}"
echo "Spoke Subnets: ${SPOKE_SUBNET1}, ${SPOKE_SUBNET2}, ${SPOKE_SUBNET3}"
echo ""
echo "Ready to deploy!"
echo ""
