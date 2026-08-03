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