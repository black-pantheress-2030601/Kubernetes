# Cross-Account Nodegroups Architecture

## Overview

This architecture has:
- **Hub Account**: EKS control plane only (no nodes, or optional hub nodes)
- **Spoke Accounts**: EC2 nodes only (no EKS cluster), joining the hub cluster

```
┌──────────────────────────────────────────────────┐
│         Hub Account (123456789012)               │
│                                                   │
│  ┌────────────────────────────────────────────┐ │
│  │     EKS Cluster Control Plane              │ │
│  │     - API Server                           │ │
│  │     - etcd                                 │ │
│  │     - Scheduler                            │ │
│  │     - Controller Manager                   │ │
│  │                                            │ │
│  │  Cluster Security Group: sg-hub123        │ │
│  │  Endpoint: https://ABC.eks.amazonaws.com  │ │
│  └────────────────────────────────────────────┘ │
│                                                   │
│  Optional: ECR, CloudWatch, Prometheus, etc.     │
└───────────────────┬──────────────────────────────┘
                    │
                    │ Node Registration
                    │ (IAM Authentication)
                    │
      ┌─────────────┼─────────────┐
      │             │             │
┌─────▼─────┐ ┌────▼──────┐ ┌───▼────────┐
│  Spoke 1  │ │  Spoke 2  │ │  Spoke 3   │
│  Customer1│ │  Customer2│ │  Customer3 │
│           │ │           │ │            │
│ ┌───────┐ │ │ ┌───────┐ │ │ ┌────────┐│
│ │ Nodes │ │ │ │ Nodes │ │ │ │ Nodes  ││
│ │  ASG  │ │ │ │  ASG  │ │ │ │  ASG   ││
│ └───────┘ │ │ └───────┘ │ │ └────────┘│
│           │ │           │ │            │
│ VPC-1     │ │ VPC-2     │ │ VPC-3      │
└───────────┘ └───────────┘ └────────────┘
```

## How Cross-Account Node Authentication Works

### 1. Node Bootstrap Process

When a node starts in a spoke account:

```
┌──────────────────────────────────────────────────────────────┐
│ Step 1: EC2 Instance launches with UserData                  │
│                                                               │
│ [settings.kubernetes]                                         │
│ cluster-name = "hub-shared-cluster"                          │
│ api-server = "https://ABC.eks.amazonaws.com"                 │
│ cluster-certificate = "LS0tLS1CRU..."                        │
└──────────────────────────────────────────────────────────────┘
                            ↓
┌──────────────────────────────────────────────────────────────┐
│ Step 2: Kubelet starts and needs authentication              │
│                                                               │
│ Kubelet → Uses Instance Profile to get IAM credentials       │
│        → Calls: sts:GetCallerIdentity                        │
│        → Gets: arn:aws:iam::SPOKE-ACCOUNT:role/NodeRole     │
└──────────────────────────────────────────────────────────────┘
                            ↓
┌──────────────────────────────────────────────────────────────┐
│ Step 3: Create AWS SigV4 signed token                        │
│                                                               │
│ Token includes:                                               │
│ - IAM Role ARN from spoke account                            │
│ - Timestamp                                                   │
│ - Signature (proves identity)                                │
└──────────────────────────────────────────────────────────────┘
                            ↓
┌──────────────────────────────────────────────────────────────┐
│ Step 4: Call EKS API with token                              │
│                                                               │
│ POST https://ABC.eks.amazonaws.com/                          │
│ Authorization: Bearer <AWS-SIGV4-TOKEN>                      │
└──────────────────────────────────────────────────────────────┘
                            ↓
┌──────────────────────────────────────────────────────────────┐
│ Step 5: EKS validates cross-account IAM identity             │
│                                                               │
│ Control Plane → Calls AWS STS to verify signature            │
│              → Confirms: arn:aws:iam::SPOKE:role/NodeRole    │
│              → Checks Access Entries for this ARN            │
└──────────────────────────────────────────────────────────────┘
                            ↓
┌──────────────────────────────────────────────────────────────┐
│ Step 6: Map to Kubernetes identity                           │
│                                                               │
│ Access Entry (Type: EC2_LINUX) maps:                         │
│ IAM: arn:aws:iam::SPOKE:role/NodeRole                       │
│   → K8s User: system:node:ip-10-0-1-23.ec2.internal         │
│   → K8s Groups: [system:nodes, system:bootstrappers]        │
└──────────────────────────────────────────────────────────────┘
                            ↓
┌──────────────────────────────────────────────────────────────┐
│ Step 7: Node joins cluster                                   │
│                                                               │
│ kubectl get nodes                                             │
│ NAME                          STATUS   ROLE    AGE           │
│ ip-10-0-1-23.ec2.internal    Ready    <none>  2m            │
│                                                               │
│ Labels: customer=customer1, account=SPOKE-ACCOUNT-ID         │
└──────────────────────────────────────────────────────────────┘
```

### 2. Why This Works Cross-Account

**Key insight:** AWS IAM is account-agnostic for authentication.

- When EKS validates the token, it calls `sts:GetCallerIdentity` 
- STS verifies the signature regardless of which account the role is in
- The full ARN `arn:aws:iam::SPOKE-ACCOUNT:role/NodeRole` is what matters
- EKS Access Entries can reference IAM principals from **any** AWS account

### 3. Network Connectivity

For cross-account nodes to reach the control plane:

**Option A: Public Endpoint (Simplest)**
```yaml
EndpointPublicAccess: true
PublicAccessCidrs: ["0.0.0.0/0"]
```
- Nodes reach control plane over internet
- IAM authentication ensures security
- No VPC peering needed
- NAT Gateway in spoke VPC required

**Option B: Private Endpoint + VPC Peering**
```yaml
EndpointPublicAccess: false
EndpointPrivateAccess: true
```
- Requires VPC peering or Transit Gateway
- More complex networking
- Better for high-security environments

**Option C: Hybrid**
```yaml
EndpointPublicAccess: true
EndpointPrivateAccess: true
PublicAccessCidrs: ["10.0.0.0/8"]  # Only private IPs
```
- Best of both worlds
- Nodes use public endpoint but restricted to RFC1918

## Deployment Guide

### Prerequisites

- Hub account with VPC and subnets
- Spoke account(s) with VPC and subnets
- AWS CLI configured with profiles for each account

### Step 1: Deploy Hub Cluster

```bash
# In hub account
aws cloudformation create-stack \
  --stack-name hub-cluster \
  --template-body file://cfn/hub-cluster-with-cross-account-nodes.yaml \
  --parameters \
    ParameterKey=ClusterName,ParameterValue=hub-shared-cluster \
    ParameterKey=VpcId,ParameterValue=vpc-hub123 \
    ParameterKey=Subnet1Id,ParameterValue=subnet-hub1 \
    ParameterKey=Subnet2Id,ParameterValue=subnet-hub2 \
    ParameterKey=Subnet3Id,ParameterValue=subnet-hub3 \
    ParameterKey=SpokeAccount1Id,ParameterValue=111111111111 \
    ParameterKey=SpokeAccount2Id,ParameterValue=222222222222 \
  --capabilities CAPABILITY_NAMED_IAM \
  --profile hub

# Wait for completion
aws cloudformation wait stack-create-complete \
  --stack-name hub-cluster \
  --profile hub

# Get cluster details
HUB_CLUSTER_NAME=$(aws cloudformation describe-stacks \
  --stack-name hub-cluster \
  --query 'Stacks[0].Outputs[?OutputKey==`ClusterName`].OutputValue' \
  --output text \
  --profile hub)

HUB_CLUSTER_ENDPOINT=$(aws cloudformation describe-stacks \
  --stack-name hub-cluster \
  --query 'Stacks[0].Outputs[?OutputKey==`ClusterEndpoint`].OutputValue' \
  --output text \
  --profile hub)

HUB_CLUSTER_CA=$(aws cloudformation describe-stacks \
  --stack-name hub-cluster \
  --query 'Stacks[0].Outputs[?OutputKey==`ClusterCA`].OutputValue' \
  --output text \
  --profile hub)

HUB_CLUSTER_SG=$(aws cloudformation describe-stacks \
  --stack-name hub-cluster \
  --query 'Stacks[0].Outputs[?OutputKey==`ClusterSecurityGroupId`].OutputValue' \
  --output text \
  --profile hub)

echo "Cluster Name: $HUB_CLUSTER_NAME"
echo "Endpoint: $HUB_CLUSTER_ENDPOINT"
echo "Security Group: $HUB_CLUSTER_SG"
```

### Step 2: Configure kubectl for Hub Cluster

```bash
# Get kubeconfig
aws eks update-kubeconfig \
  --name $HUB_CLUSTER_NAME \
  --region us-east-1 \
  --profile hub

# Verify access
kubectl get nodes
# Should show no nodes yet (only control plane exists)

kubectl get svc
# Should show kubernetes service
```

### Step 3: Deploy Spoke Nodegroup

```bash
# In spoke account
aws cloudformation create-stack \
  --stack-name customer1-nodes \
  --template-body file://cfn/spoke-nodegroup-only.yaml \
  --parameters \
    ParameterKey=HubAccountId,ParameterValue=999999999999 \
    ParameterKey=HubClusterName,ParameterValue=$HUB_CLUSTER_NAME \
    ParameterKey=HubClusterEndpoint,ParameterValue=$HUB_CLUSTER_ENDPOINT \
    ParameterKey=HubClusterCA,ParameterValue=$HUB_CLUSTER_CA \
    ParameterKey=HubClusterSecurityGroupId,ParameterValue=$HUB_CLUSTER_SG \
    ParameterKey=NodeGroupName,ParameterValue=customer1-nodes \
    ParameterKey=CustomerName,ParameterValue=customer1 \
    ParameterKey=VpcId,ParameterValue=vpc-spoke123 \
    ParameterKey=Subnet1Id,ParameterValue=subnet-spoke1 \
    ParameterKey=Subnet2Id,ParameterValue=subnet-spoke2 \
    ParameterKey=Subnet3Id,ParameterValue=subnet-spoke3 \
  --capabilities CAPABILITY_NAMED_IAM \
  --profile spoke1

# Wait for completion
aws cloudformation wait stack-create-complete \
  --stack-name customer1-nodes \
  --profile spoke1

# Get node role ARN
SPOKE_NODE_ROLE=$(aws cloudformation describe-stacks \
  --stack-name customer1-nodes \
  --query 'Stacks[0].Outputs[?OutputKey==`NodeRoleArn`].OutputValue' \
  --output text \
  --profile spoke1)

echo "Spoke Node Role: $SPOKE_NODE_ROLE"
```

### Step 4: Add Access Entry in Hub Account

**This is the critical step that allows cross-account nodes to join!**

```bash
# In hub account, create access entry for spoke node role
aws eks create-access-entry \
  --cluster-name $HUB_CLUSTER_NAME \
  --principal-arn $SPOKE_NODE_ROLE \
  --type EC2_LINUX \
  --region us-east-1 \
  --profile hub

# Associate the worker node policy
aws eks associate-access-policy-association \
  --cluster-name $HUB_CLUSTER_NAME \
  --principal-arn $SPOKE_NODE_ROLE \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSWorkerNodePolicy \
  --access-scope type=cluster \
  --region us-east-1 \
  --profile hub
```

### Step 5: Verify Nodes Join

```bash
# Wait a few minutes for nodes to bootstrap
sleep 180

# Check nodes
kubectl get nodes
# Should see nodes from spoke account!

kubectl get nodes --show-labels
# Should see labels: customer=customer1, account=111111111111

# Check node details
kubectl describe node <node-name>
# Should show provider ID: aws:///us-east-1a/i-xxxxx (spoke account instance)
```

### Step 6: Test Workload Deployment

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: customer1
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-app
  namespace: customer1
spec:
  replicas: 3
  selector:
    matchLabels:
      app: test
  template:
    metadata:
      labels:
        app: test
    spec:
      nodeSelector:
        customer: customer1
      containers:
      - name: nginx
        image: nginx:latest
        ports:
        - containerPort: 80
EOF

# Verify pods scheduled on spoke nodes
kubectl get pods -n customer1 -o wide
```

## Security Considerations

### 1. IAM Permissions

**Spoke Node Role needs:**
- `AmazonEKSWorkerNodePolicy` - Join cluster
- `AmazonEC2ContainerRegistryReadOnly` - Pull images
- `AmazonEKS_CNI_Policy` - Networking

**Spoke Node Role should NOT have:**
- `eks:CreateCluster`, `eks:DeleteCluster` - Control plane operations
- `eks:CreateAccessEntry` - Only hub account should manage access

### 2. Network Security

**Hub Cluster Security Group:**
- Ingress from spoke node security groups on ports 443, 1025-65535
- Or use cluster-managed security group (automatic)

**Spoke Node Security Group:**
- Egress to hub cluster security group
- Egress to 0.0.0.0/0 for pulling images, reaching API

### 3. Pod Security

Use node selectors to ensure customers only use their nodes:

```yaml
spec:
  nodeSelector:
    customer: customer1  # Enforces pod placement
```

Or use taints/tolerations:

```yaml
# On spoke nodes (in launch template)
[settings.kubernetes.node-taints]
customer = "customer1:NoSchedule"

# In customer pods
spec:
  tolerations:
  - key: customer
    operator: Equal
    value: customer1
    effect: NoSchedule
```

## Cost Analysis

### Hub-Only Cluster (No Nodes)
- EKS Control Plane: **$73/month**
- Total: **$73/month**

### 3 Spoke Accounts with Nodes
- Hub Control Plane: $73/month
- Spoke 1 nodes (3x m5.large): ~$300/month
- Spoke 2 nodes (3x m5.large): ~$300/month
- Spoke 3 nodes (3x m5.large): ~$300/month
- **Total: ~$973/month**

**vs. 3 Separate EKS Clusters:**
- 3x EKS Control Planes: 3 × $73 = $219/month
- 3x Node groups: 3 × $300 = $900/month
- **Total: ~$1,119/month**

**Savings: ~$146/month (13% cheaper)** by sharing one control plane

## Advantages

✅ **Cost Savings**: One control plane for multiple customers  
✅ **Strong Isolation**: Customer nodes in separate AWS accounts  
✅ **Centralized Management**: Single control plane to upgrade/manage  
✅ **Flexible Sizing**: Each spoke can have different node sizes/counts  
✅ **Billing Separation**: Each spoke account pays for their own nodes  

## Disadvantages

❌ **Blast Radius**: Control plane issue affects all customers  
❌ **Shared etcd**: All cluster state in one place  
❌ **Upgrade Coordination**: Can't upgrade spoke clusters independently  
❌ **Network Complexity**: Must ensure spoke nodes can reach hub endpoint  

## Troubleshooting

### Nodes Not Joining

**Check 1: Access Entry exists**
```bash
aws eks list-access-entries \
  --cluster-name hub-shared-cluster \
  --profile hub
```

**Check 2: Node can reach API endpoint**
```bash
# SSH to node (via Systems Manager)
aws ssm start-session --target i-xxxxx --profile spoke1

# From node
curl -k https://ABC.eks.amazonaws.com/

# Should get "Unauthorized" (good - means it's reachable)
```

**Check 3: IAM role is correct**
```bash
# On node
curl http://169.254.169.254/latest/meta-data/iam/security-credentials/

# Should show NodeRole name
```

**Check 4: Kubelet logs**
```bash
# On Bottlerocket node
apiclient exec admin bash
journalctl -u kubelet -f

# Look for authentication errors
```

### Common Errors

**Error: "Unauthorized"**
- Access Entry not created in hub account
- Wrong IAM role ARN in Access Entry
- Policy not associated with Access Entry

**Error: "Forbidden"**
- Access Entry exists but policy not attached
- Wrong policy attached (needs AmazonEKSWorkerNodePolicy)

**Error: "Connection refused"**
- Network path broken (check NAT Gateway, routing)
- Wrong endpoint in user-data
- Security groups blocking traffic

## Alternative: Managed Node Groups Cross-Account

AWS EKS Managed Node Groups **do NOT support cross-account** directly. You must use self-managed nodes (ASG + Launch Template) like in this architecture.

## Next Steps

- Add more spoke accounts by repeating steps 3-5
- Set up cross-account ECR access for shared images
- Implement centralized logging/monitoring
- Set up RBAC with namespace isolation per customer
- Configure cluster autoscaler per spoke nodegroup
