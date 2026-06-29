# Cross-Account EKS Quick Reference

## Deployment Commands

```bash
# 1. Setup AWS profiles
./setup-aws-profiles.sh

# 2. Gather VPC info
./gather-vpc-info.sh

# 3. Deploy everything
./deploy-cross-account-eks.sh

# 4. Test deployment
kubectl apply -f test-deployment.yaml
```

## Useful kubectl Commands

```bash
# View all nodes
kubectl get nodes -o wide

# View nodes by customer
kubectl get nodes --selector=customer=customer1

# View node details
kubectl describe node <node-name>

# View all pods across namespaces
kubectl get pods -A -o wide

# View customer pods
kubectl get pods -n customer1 -o wide

# View pod logs
kubectl logs <pod-name> -n customer1

# Check cluster info
kubectl cluster-info

# View all namespaces
kubectl get namespaces
```

## AWS CLI Commands

### Hub Account

```bash
# View EKS cluster
aws eks describe-cluster --name hub-shared-cluster --profile hub

# List access entries
aws eks list-access-entries --cluster-name hub-shared-cluster --profile hub

# View access entry details
aws eks describe-access-entry --cluster-name hub-shared-cluster --principal-arn <ARN> --profile hub

# List associated policies
aws eks list-associated-access-policies --cluster-name hub-shared-cluster --principal-arn <ARN> --profile hub

# View CloudFormation stack
aws cloudformation describe-stacks --stack-name hub-eks-cluster --profile hub

# View stack events
aws cloudformation describe-stack-events --stack-name hub-eks-cluster --profile hub
```

### Spoke Account

```bash
# View EC2 instances
aws ec2 describe-instances --filters "Name=tag:customer,Values=customer1" --profile spoke1

# View Auto Scaling Group
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names customer1-nodes-asg --profile spoke1

# View CloudFormation stack
aws cloudformation describe-stacks --stack-name spoke-customer1-nodes --profile spoke1

# Connect to node via SSM
aws ssm start-session --target <instance-id> --profile spoke1
```

## Troubleshooting Commands

```bash
# Check if nodes are ready
kubectl get nodes
# STATUS should be "Ready"

# Check node events
kubectl describe node <node-name> | grep -A 10 Events

# Check pod events
kubectl describe pod <pod-name> -n customer1 | grep -A 10 Events

# View kubelet logs on node (via SSM)
apiclient exec admin bash
journalctl -u kubelet -f

# Check EKS access entries
aws eks list-access-entries --cluster-name hub-shared-cluster --profile hub

# Verify IAM role
aws sts get-caller-identity --profile spoke1

# Test node connectivity to API server (from node)
curl -k https://<cluster-endpoint>/
# Should get "Unauthorized" (good - means reachable)
```

## Common Operations

### Scale Nodegroup

```bash
# Update desired capacity
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name customer1-nodes-asg \
  --desired-capacity 5 \
  --region ap-southeast-2 \
  --profile spoke1
```

### Update Node Instance Type

```bash
# Update CloudFormation stack
aws cloudformation update-stack \
  --stack-name spoke-customer1-nodes \
  --use-previous-template \
  --parameters \
    ParameterKey=NodeInstanceType,ParameterValue=m5.xlarge \
    ParameterKey=HubAccountId,UsePreviousValue=true \
    ParameterKey=HubClusterName,UsePreviousValue=true \
    ... (all other parameters) \
  --capabilities CAPABILITY_NAMED_IAM \
  --region ap-southeast-2 \
  --profile spoke1
```

### Drain and Cordon Nodes

```bash
# Cordon node (prevent new pods)
kubectl cordon <node-name>

# Drain node (evict pods)
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# Uncordon node
kubectl uncordon <node-name>
```

### View Resource Usage

```bash
# Node resource usage
kubectl top nodes

# Pod resource usage
kubectl top pods -n customer1

# Describe node capacity
kubectl describe node <node-name> | grep -A 5 Capacity
```

## Configuration Files

```bash
# View current config
source /tmp/eks-deployment-config.env
env | grep -E "(HUB|SPOKE|AWS)"

# View deployment info
cat /tmp/eks-deployment-info.txt

# View kubeconfig
kubectl config view

# View current context
kubectl config current-context
```

## Cleanup Commands

```bash
# Delete test deployment
kubectl delete -f test-deployment.yaml

# Delete spoke stack
aws cloudformation delete-stack --stack-name spoke-customer1-nodes --region ap-southeast-2 --profile spoke1

# Delete hub stack (after all spoke stacks deleted)
aws cloudformation delete-stack --stack-name hub-eks-cluster --region ap-southeast-2 --profile hub

# Remove kubeconfig context
kubectl config delete-context <context-name>
```

## Useful Filters

```bash
# Get node IPs
kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}'

# Get node instance IDs
kubectl get nodes -o jsonpath='{.items[*].spec.providerID}' | tr ' ' '\n' | sed 's/.*\///'

# Get pods on specific node
kubectl get pods -A --field-selector spec.nodeName=<node-name>

# Get pods by customer label
kubectl get pods -A -l customer=customer1 -o wide
```

## Important ARNs and IDs

```bash
# Hub cluster ARN
arn:aws:eks:ap-southeast-2:<HUB_ACCOUNT_ID>:cluster/hub-shared-cluster

# Spoke node role ARN
arn:aws:iam::<SPOKE_ACCOUNT_ID>:role/customer1-nodes-role

# Worker node policy ARN
arn:aws:eks::aws:cluster-access-policy/AmazonEKSWorkerNodePolicy
```

## Emergency Procedures

### Nodes Not Joining

1. Check access entry exists
2. Verify policy association
3. Check node security group rules
4. Verify NAT Gateway in spoke VPC
5. Check node IAM role permissions
6. Review kubelet logs on node

### Cluster Unresponsive

1. Check CloudWatch metrics for control plane
2. Verify API endpoint is accessible
3. Check kubectl context is correct
4. Verify AWS credentials are valid

### Need to Force Recreate Nodes

```bash
# Terminate instances (ASG will recreate)
aws autoscaling set-desired-capacity --auto-scaling-group-name customer1-nodes-asg --desired-capacity 0 --profile spoke1
sleep 60
aws autoscaling set-desired-capacity --auto-scaling-group-name customer1-nodes-asg --desired-capacity 3 --profile spoke1
```

## Cost Tracking

```bash
# View running instances
aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running" \
  --query 'Reservations[*].Instances[*].[InstanceId,InstanceType,LaunchTime]' \
  --profile spoke1

# View EBS volumes
aws ec2 describe-volumes \
  --filters "Name=tag:customer,Values=customer1" \
  --query 'Volumes[*].[VolumeId,Size,VolumeType,State]' \
  --profile spoke1

# View NAT Gateways
aws ec2 describe-nat-gateways --profile spoke1
```

## Monitoring

```bash
# View cluster health
aws eks describe-cluster --name hub-shared-cluster --query 'cluster.health' --profile hub

# View control plane logs (in CloudWatch)
aws logs tail /aws/eks/hub-shared-cluster/cluster --follow --profile hub

# View node system logs (on node via SSM)
journalctl -u kubelet -f
journalctl -u containerd -f
```
