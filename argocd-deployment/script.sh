aws cloudformation create-stack \
  --stack-name standalone-eks-cluster \
  --template-body file://cfn/standalone-eks-cluster.yaml \
  --parameters \
    ParameterKey=ClusterName,ParameterValue=standalone-cluster \
    ParameterKey=VpcId,ParameterValue=vpc-0940d59dd70f7f67d \
    ParameterKey=Subnet1Id,ParameterValue=subnet-066506c4fa0e78004 \
    ParameterKey=Subnet2Id,ParameterValue=subnet-0f697a017d3f60635 \
    ParameterKey=Subnet3Id,ParameterValue=subnet-0d419041a14fc9eb5 \
  --capabilities CAPABILITY_NAMED_IAM \
  --region ap-southeast-2

aws cloudformation wait stack-create-complete \
  --stack-name standalone-eks-cluster --region ap-southeast-2

aws eks update-kubeconfig --name standalone-cluster --region ap-southeast-2

kubectl get nodes