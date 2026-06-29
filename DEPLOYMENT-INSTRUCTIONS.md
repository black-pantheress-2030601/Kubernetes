# Cross-Account EKS Deployment Instructions

## Overview

This guide will deploy:
- **Hub Account**: EKS control plane in ap-southeast-2
- **Spoke Account**: Self-managed nodes that join the hub cluster

## Prerequisites

✅ Two AWS accounts (hub and spoke)  
✅ AWS CLI installed (`aws --version`)  
✅ kubectl installed (`kubectl version --client`)  
✅ Access keys/credentials for both accounts  
✅ Existing VPCs with at least 3 subnets in each account  

## Deployment Steps

### Step 1: Configure AWS Profiles

Run the profile setup script:

```bash
./setup-aws-profiles.sh
```

You'll be prompted for:
- Hub account ID and credentials
- Spoke account ID and credentials
- Region (default: ap-southeast-2)

This creates two AWS CLI profiles:
- `hub` - for the hub account
- `spoke1` - for the spoke account

**Verify profiles work:**
```bash
aws sts get-caller-identity --profile hub
aws sts get-caller-identity --profile spoke1
```

### Step 2: Gather VPC Information

Run the VPC gathering script:

```bash
./gather-vpc-info.sh
```

This will:
1. List all VPCs in hub account
2. Show subnets in selected hub VPC
3. List all VPCs in spoke account
4. Show subnets in selected spoke VPC

**Select subnets in different availability zones** for high availability.

### Step 3: Deploy Everything

Run the main deployment script:

```bash
./deploy-cross-account-eks.sh
```

This script will:
1. ✅ Deploy EKS control plane in hub account (~15 minutes)
2. ✅ Configure kubectl to access hub cluster
3. ✅ Deploy spoke nodegroup in spoke account (~5-10 minutes)
4. ✅ Create EKS access entry for cross-account authentication
5. ✅ Verify nodes joined the cluster

**Total deployment time: ~20-25 minutes**

### Step 4: Test the Deployment

Deploy a test application:

```bash
kubectl apply -f test-deployment.yaml
```

Verify pods are running on spoke account nodes:

```bash
kubectl get pods -n customer1 -o wide
```

Check node details:

```bash
kubectl get nodes -o wide
kubectl get nodes --selector=customer=customer1 -o wide
kubectl describe node <node-name>
```

## What Gets Deployed

### Hub Account Resources

- **EKS Cluster**: `hub-shared-cluster`
  - Control plane only (API server, etcd, scheduler, controller manager)
  - Add-ons: VPC CNI, CoreDNS, kube-proxy, EBS CSI driver, pod identity agent
  - Public endpoint enabled for cross-account node access
  
- **IAM Role**: `hub-shared-cluster-cluster-role`
  - Used by EKS control plane
  
- **Security Group**: Cluster security group
  - Allows spoke nodes to communicate with control plane

### Spoke Account Resources

- **Auto Scaling Group**: 3 Bottlerocket EC2 instances (m5.large)
  - Configured to join hub cluster
  - Tagged with `customer=customer1`
  
- **IAM Role**: `customer1-nodes-role`
  - Node permissions (worker, ECR, CNI, SSM)
  - Cross-account ECR pull permissions
  
- **Instance Profile**: For EC2 instances to assume node role
  
- **Security Group**: Node security group
  - Allows communication with hub cluster control plane
  - Node-to-node communication

- **Launch Template**: With Bottlerocket user-data
  - Cluster name, endpoint, CA certificate
  - Node labels for customer isolation

### Hub Cluster Configuration

- **Access Entry**: Maps spoke node IAM role → Kubernetes identity
  - Type: `EC2_LINUX`
  - Policy: `AmazonEKSWorkerNodePolicy`
  - Allows cross-account nodes to authenticate and join

## Architecture Diagram

```
┌──────────────────────────────────────────────┐
│         Hub Account (ap-southeast-2)         │
│                                               │
│  ┌────────────────────────────────────────┐  │
│  │   EKS Cluster: hub-shared-cluster     │  │
│  │   - API Server (public endpoint)      │  │
│  │   - etcd                               │  │
│  │   - Scheduler                          │  │
│  │   - Controller Manager                 │  │
│  │                                        │  │
│  │   Endpoint: https://ABC.eks.aws.com   │  │
│  └────────────────────────────────────────┘  │
│                                               │
└───────────────────┬───────────────────────────┘
                    │
                    │ IAM Authentication
                    │ (AWS SigV4 tokens)
                    │
┌───────────────────▼───────────────────────────┐
│      Spoke Account (ap-southeast-2)           │
│                                               │
│  ┌────────────────────────────────────────┐  │
│  │   Auto Scaling Group                   │  │
│  │   - 3x Bottlerocket nodes (m5.large)   │  │
│  │   - Label: customer=customer1          │  │
│  │   - IAM Role: customer1-nodes-role     │  │
│  └────────────────────────────────────────┘  │
│                                               │
│  EC2 Instances → Authenticate via IAM →      │
│                  Join hub cluster             │
└───────────────────────────────────────────────┘
```

## Verification Checklist

After deployment completes, verify:

- [ ] Hub cluster is accessible: `kubectl get svc`
- [ ] Nodes are registered: `kubectl get nodes`
- [ ] Nodes have correct labels: `kubectl get nodes --show-labels`
- [ ] Nodes are from spoke account: Check `ProviderID` in node details
- [ ] Test pods can schedule: `kubectl get pods -n customer1`
- [ ] Pods run on spoke nodes only: `kubectl get pods -n customer1 -o wide`

## Accessing the Cluster

The deployment script automatically configures kubectl. Your kubeconfig is at:
```
~/.kube/config
```

To manually update kubeconfig:
```bash
aws eks update-kubeconfig --name hub-shared-cluster --region ap-southeast-2 --profile hub
```

Current context:
```bash
kubectl config current-context
```

## Cost Estimate

### Monthly Costs (ap-southeast-2)

**Hub Account:**
- EKS Control Plane: $73.00/month
- **Subtotal: $73.00/month**

**Spoke Account:**
- 3x m5.large instances: ~$0.116/hour × 3 × 730 hours = ~$254/month
- EBS volumes: 3 × (30GB + 50GB) × $0.10/GB = ~$24/month
- NAT Gateway: ~$44/month + data transfer
- **Subtotal: ~$322/month**

**Total: ~$395/month**

### Cost Comparison

| Architecture | Control Planes | Nodes | Total/month |
|--------------|---------------|-------|-------------|
| Separate clusters | 2 × $73 = $146 | $322 | **$468** |
| Cross-account nodes | 1 × $73 = $73 | $322 | **$395** |
| **Savings** | | | **$73/month** |

## Troubleshooting

### Nodes Not Joining

**Check access entry:**
```bash
aws eks list-access-entries --cluster-name hub-shared-cluster --region ap-southeast-2 --profile hub
```

**Check if policy is associated:**
```bash
aws eks list-associated-access-policies --cluster-name hub-shared-cluster --principal-arn <NODE_ROLE_ARN> --region ap-southeast-2 --profile hub
```

**Check node logs (via SSM):**
```bash
# Get instance ID
aws ec2 describe-instances --filters "Name=tag:customer,Values=customer1" --query 'Reservations[*].Instances[*].InstanceId' --output text --profile spoke1

# Connect to instance
aws ssm start-session --target <INSTANCE_ID> --profile spoke1

# On the node
apiclient exec admin bash
journalctl -u kubelet -f
```

### Common Errors

**"Unauthorized" errors:**
- Access entry not created
- Wrong IAM role ARN
- Policy not associated

**"Connection refused":**
- NAT Gateway missing in spoke VPC
- Security group rules incorrect
- Wrong cluster endpoint in user-data

**Pods pending:**
- Check node taints: `kubectl describe node <node-name>`
- Check pod node selector matches: `kubectl describe pod <pod-name> -n customer1`

## Cleanup

To delete everything:

```bash
# Delete spoke nodegroup first
aws cloudformation delete-stack --stack-name spoke-customer1-nodes --region ap-southeast-2 --profile spoke1

# Wait for deletion
aws cloudformation wait stack-delete-complete --stack-name spoke-customer1-nodes --region ap-southeast-2 --profile spoke1

# Delete hub cluster
aws cloudformation delete-stack --stack-name hub-eks-cluster --region ap-southeast-2 --profile hub

# Wait for deletion
aws cloudformation wait stack-delete-complete --stack-name hub-eks-cluster --region ap-southeast-2 --profile hub
```

**Note:** You cannot delete the hub cluster while spoke nodes are still registered. Always delete spoke stacks first.

## Adding More Spoke Accounts

To add another spoke account with its own nodegroup:

1. Configure credentials for the new spoke account:
```bash
aws configure --profile spoke2
```

2. Deploy another spoke stack:
```bash
aws cloudformation create-stack \
  --stack-name spoke-customer2-nodes \
  --template-body file://cfn/spoke-nodegroup-only.yaml \
  --parameters \
    ParameterKey=HubAccountId,ParameterValue=<HUB_ACCOUNT_ID> \
    ParameterKey=HubClusterName,ParameterValue=hub-shared-cluster \
    ParameterKey=HubClusterEndpoint,ParameterValue=<ENDPOINT> \
    ParameterKey=HubClusterCA,ParameterValue=<CA> \
    ParameterKey=HubClusterSecurityGroupId,ParameterValue=<SG_ID> \
    ParameterKey=NodeGroupName,ParameterValue=customer2-nodes \
    ParameterKey=CustomerName,ParameterValue=customer2 \
    ParameterKey=VpcId,ParameterValue=<SPOKE2_VPC> \
    ParameterKey=Subnet1Id,ParameterValue=<SPOKE2_SUBNET1> \
    ParameterKey=Subnet2Id,ParameterValue=<SPOKE2_SUBNET2> \
    ParameterKey=Subnet3Id,ParameterValue=<SPOKE2_SUBNET3> \
  --capabilities CAPABILITY_NAMED_IAM \
  --region ap-southeast-2 \
  --profile spoke2
```

3. Create access entry for the new node role:
```bash
SPOKE2_NODE_ROLE=$(aws cloudformation describe-stacks \
  --stack-name spoke-customer2-nodes \
  --query 'Stacks[0].Outputs[?OutputKey==`NodeRoleArn`].OutputValue' \
  --output text \
  --region ap-southeast-2 \
  --profile spoke2)

aws eks create-access-entry \
  --cluster-name hub-shared-cluster \
  --principal-arn ${SPOKE2_NODE_ROLE} \
  --type EC2_LINUX \
  --region ap-southeast-2 \
  --profile hub

aws eks associate-access-policy-association \
  --cluster-name hub-shared-cluster \
  --principal-arn ${SPOKE2_NODE_ROLE} \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSWorkerNodePolicy \
  --access-scope type=cluster \
  --region ap-southeast-2 \
  --profile hub
```

## Security Considerations

1. **Node Isolation**: Use node selectors and taints/tolerations to ensure customers only use their nodes
2. **Network Policies**: Implement Kubernetes Network Policies for pod-to-pod isolation
3. **RBAC**: Set up namespaces and RBAC per customer
4. **Secrets**: Use separate secret stores per customer (AWS Secrets Manager with IRSA)
5. **Audit Logging**: EKS audit logs are enabled - send to CloudWatch Logs

## Next Steps

1. Set up cross-account ECR for shared container images
2. Configure centralized logging (FluentBit → CloudWatch)
3. Set up monitoring (Prometheus → AMP)
4. Implement customer namespace isolation with RBAC
5. Configure cluster autoscaler per nodegroup
6. Set up GitOps with ArgoCD

## Support

For issues or questions:
- Check CloudFormation stack events for deployment errors
- Review EKS cluster logs in CloudWatch
- Check node logs via SSM Session Manager
- Review the CROSS-ACCOUNT-NODEGROUPS.md for detailed architecture
