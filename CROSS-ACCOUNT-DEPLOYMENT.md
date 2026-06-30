# Cross-Account EKS Cluster Deployment

## Architecture

This deployment uses **separate complete EKS clusters** in each account - the recommended pattern for true multi-tenant isolation.

```
┌──────────────────────────────────────────────────────┐
│     Hub Account: WorkloadConfig (969341426174)       │
│                                                       │
│  • (Optional) Shared Services Cluster                │
│  • Amazon ECR (container registry)                   │
│  • CloudWatch Logs (centralized logging)             │
│  • Amazon Managed Prometheus (monitoring)            │
│  • S3 Bucket (shared artifacts)                      │
└──────────────────────────────────────────────────────┘
                          │
                Cross-Account IAM Roles
                          │
┌──────────────────────────────────────────────────────┐
│   Spoke Account: SandboxWC (706863000784)            │
│                                                       │
│  ┌────────────────────────────────────────────┐     │
│  │   Complete EKS Cluster: customer1-prod     │     │
│  │   - Control Plane (in spoke account)       │     │
│  │   - 2x m5.large Bottlerocket nodes         │     │
│  │   - Full add-ons (VPC CNI, CoreDNS, etc.)  │     │
│  │   - Own VPC and subnets                    │     │
│  └────────────────────────────────────────────┘     │
│                                                       │
│  Cross-Account Access:                               │
│  • Pull images from Hub ECR                          │
│  • Send logs to Hub CloudWatch (optional)            │
│  • Send metrics to Hub Prometheus (optional)         │
└──────────────────────────────────────────────────────┘
```

## Current Deployment Status

### Spoke Cluster (customer1-prod)
- **Status**: ✅ Deployed and verified
- **Account**: SandboxWC (706863000784)
- **Stack Name**: `customer1-prod-cluster`
- **Region**: ap-southeast-2
- **VPC**: vpc-0166a4d3e28ff3da1
- **Nodes**: 2x m5.large Bottlerocket instances (both Ready)
- **Test Application**: 3 nginx pods running successfully

### Components Being Created
1. EKS Control Plane (Kubernetes 1.32)
2. VPC Security Groups
3. IAM Roles (Cluster + Node + Optional cross-account roles)
4. Launch Template with Bottlerocket
5. Auto Scaling Group
6. EKS Add-ons (VPC CNI, CoreDNS, kube-proxy, EBS CSI, Pod Identity)

## Key Features

### ✅ Strong Isolation
- Complete EKS cluster in spoke account
- Separate control plane per customer
- Full VPC isolation
- No shared compute resources

### ✅ Cross-Account Resource Sharing
- Spoke nodes can pull images from Hub ECR
- (Optional) Send logs to Hub CloudWatch
- (Optional) Send metrics to Hub Prometheus
- IAM role-based authentication

### ✅ Customer Control
- Full cluster admin access in their account
- Independent cluster upgrades
- Customize Kubernetes versions
- Own node configuration

## Files Used

1. **`cfn/spoke-customer-cluster.yaml`**
   - Complete EKS cluster template
   - Includes control plane + nodes + add-ons
   - Cross-account IAM roles for Hub services
   - Bottlerocket OS configuration

2. **`cfn/hub-shared-services.yaml`**  
   - (Optional) Hub cluster for shared services
   - ECR repositories with cross-account policies
   - CloudWatch Logs for centralized logging
   - Amazon Managed Prometheus for monitoring
   - Note: Has some resource type compatibility issues

## Post-Deployment Steps

Once the spoke cluster is deployed:

### 1. Configure kubectl
```bash
aws eks update-kubeconfig \
  --name customer1-prod \
  --region ap-southeast-2 \
  --profile SandboxWC
```

### 2. Add Node Role to aws-auth ConfigMap
```bash
NODE_ROLE=$(aws cloudformation describe-stacks \
  --stack-name customer1-prod-cluster \
  --region ap-southeast-2 \
  --profile SandboxWC \
  --query 'Stacks[0].Outputs[?OutputKey==`NodeRoleArn`].OutputValue' \
  --output text)

kubectl edit configmap aws-auth -n kube-system

# Add under mapRoles:
# - rolearn: <NODE_ROLE_ARN>
#   username: system:node:{{EC2PrivateDNSName}}
#   groups:
#     - system:bootstrappers
#     - system:nodes
```

### 3. Verify Nodes Joined
```bash
kubectl get nodes -o wide
kubectl get pods -n kube-system
```

### 4. (Optional) Set Up Cross-Account ECR Access

If you want to pull images from Hub account ECR:

**In Hub Account**:
```bash
# Create ECR repository
aws ecr create-repository \
  --repository-name shared/app-images \
  --region ap-southeast-2 \
  --profile WorkloadConfig

# Set repository policy to allow spoke account
aws ecr set-repository-policy \
  --repository-name shared/app-images \
  --policy-text '{
    "Version": "2012-10-17",
    "Statement": [{
      "Sid": "AllowSpokeAccountPull",
      "Effect": "Allow",
      "Principal": {"AWS": "arn:aws:iam::706863000784:root"},
      "Action": [
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:BatchCheckLayerAvailability"
      ]
    }]
  }' \
  --region ap-southeast-2 \
  --profile WorkloadConfig
```

**In Spoke Account**:
The node role already has ECR pull permissions configured in the template.

## Verification Checklist

- [x] Spoke cluster deployed successfully
- [x] kubectl configured for spoke cluster
- [x] Nodes are in Ready state
- [x] System pods running (CoreDNS, VPC CNI, etc.)
- [x] Test deployment works
- [x] Service connectivity verified (nginx service responding)
- [ ] (Optional) Cross-account ECR pull tested
- [ ] (Optional) Logging to Hub CloudWatch configured
- [ ] (Optional) Metrics to Hub Prometheus configured

## Advantages of This Architecture

### vs. Cross-Account Nodes
- ✅ **Works reliably** - no aws-auth cross-account issues
- ✅ **Full control** - spoke account has complete cluster ownership
- ✅ **Better isolation** - separate control planes
- ✅ **Easier debugging** - all resources in one account
- ✅ **Standard pattern** - well-documented and supported by AWS

### vs. Single Multi-Tenant Cluster
- ✅ **Stronger security** - account-level isolation
- ✅ **Compliance** - separate billing and audit trails
- ✅ **Blast radius** - issues in one cluster don't affect others
- ✅ **Customer flexibility** - each can customize their cluster

## Cost Breakdown (per spoke cluster)

**Monthly Costs (ap-southeast-2)**:
- EKS Control Plane: $73.00
- 2x m5.large nodes: ~$0.116/hr × 2 × 730 hrs = ~$169/month
- EBS volumes: 2 × 50GB × $0.10/GB = ~$10/month
- **Total per spoke cluster: ~$252/month**

**For 3 Spoke Clusters**:
- 3 × $252 = $756/month (spoke clusters)
- Hub services (optional): ~$100-200/month  
- **Total: ~$850-950/month**

## Troubleshooting

### Spoke Cluster Deployment Issues

**Check stack status**:
```bash
aws cloudformation describe-stacks \
  --stack-name customer1-prod-cluster \
  --region ap-southeast-2 \
  --profile SandboxWC
```

**View events**:
```bash
aws cloudformation describe-stack-events \
  --stack-name customer1-prod-cluster \
  --region ap-southeast-2 \
  --profile SandboxWC \
  --max-items 20
```

### Nodes Not Joining

1. **Check security groups** - nodes need to reach control plane
2. **Verify aws-auth ConfigMap** - node role must be added
3. **Check node logs** via SSM:
   ```bash
   aws ssm start-session --target <instance-id> --profile SandboxWC
   ```

### Cross-Account ECR Pull Fails

1. **Verify ECR repository policy** in hub account
2. **Check node IAM role** has ecr:GetAuthorizationToken permission
3. **Test manually**:
   ```bash
   # From spoke node
   aws ecr get-login-password --region ap-southeast-2 | \
     docker login --username AWS --password-stdin \
     969341426174.dkr.ecr.ap-southeast-2.amazonaws.com
   ```

## Next Steps

1. ✅ Wait for spoke cluster deployment to complete (~15 minutes)
2. ✅ Configure kubectl access
3. ✅ Verify nodes joined cluster
4. ✅ Deploy test application
5. ⬜ (Optional) Set up Hub ECR repositories
6. ⬜ (Optional) Configure cross-account logging
7. ⬜ (Optional) Configure cross-account monitoring
8. ⬜ Deploy additional spoke clusters for other customers

## Critical Post-Deployment Fix Required

**Security Group Configuration**: After stack deployment, you MUST add an ingress rule to allow nodes to communicate with the control plane:

\`\`\`bash
CLUSTER_SG=$(aws eks describe-cluster --name customer1-prod --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text --region ap-southeast-2 --profile SandboxWC)
NODE_SG=$(aws ec2 describe-instances --filters "Name=tag:kubernetes.io/cluster/customer1-prod,Values=owned" --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text --region ap-southeast-2 --profile SandboxWC)

aws ec2 authorize-security-group-ingress \
  --group-id $CLUSTER_SG \
  --protocol tcp \
  --port 443 \
  --source-group $NODE_SG \
  --region ap-southeast-2 \
  --profile SandboxWC
\`\`\`

**Why**: The CloudFormation template creates ingress rules on the node SG to allow traffic FROM the cluster, but doesn't create the reverse rule on the cluster SG to allow traffic FROM the nodes. Without this, nodes cannot authenticate with the API server.

## Cleanup

**To remove spoke cluster**:
```bash
aws cloudformation delete-stack \
  --stack-name customer1-prod-cluster \
  --region ap-southeast-2 \
  --profile SandboxWC
```

**To remove hub services** (if deployed):
```bash
aws cloudformation delete-stack \
  --stack-name hub-shared-services \
  --region ap-southeast-2 \
  --profile WorkloadConfig
```

## Deployment Date
Started: 2026-06-30
Region: ap-southeast-2 (Sydney)
Kubernetes Version: 1.32
