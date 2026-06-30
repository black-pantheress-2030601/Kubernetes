# ✅ Successful Same-Account Self-Managed EKS Cluster Deployment

## Summary

Successfully deployed self-managed worker nodes using Amazon Linux 2 in the same AWS account as the EKS control plane.

## Architecture

```
┌────────────────────────────────────────────────────────┐
│     WorkloadConfig Account (969341426174)             │
│                                                         │
│  ┌──────────────────────────────────────────────┐     │
│  │   EKS Cluster: hub-shared-cluster            │     │
│  │   - Version: 1.32                            │     │
│  │   - Region: ap-southeast-2                   │     │
│  │   - Auth Mode: API_AND_CONFIG_MAP            │     │
│  └──────────────────────────────────────────────┘     │
│                          │                              │
│                          │ Same VPC                     │
│                          ▼                              │
│  ┌──────────────────────────────────────────────┐     │
│  │   Self-Managed Node Group                    │     │
│  │   - 2x m5.large instances                    │     │
│  │   - Amazon Linux 2 EKS-optimized AMI         │     │
│  │   - Auto Scaling Group                       │     │
│  │   - Labels: customer=customer1               │     │
│  └──────────────────────────────────────────────┘     │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

## Deployment Details

### Hub Cluster
- **Name**: `hub-shared-cluster`
- **Account**: 969341426174 (WorkloadConfig)
- **Version**: Kubernetes 1.32
- **Region**: ap-southeast-2 (Sydney)
- **Authentication**: API_AND_CONFIG_MAP
- **VPC**: vpc-0940d59dd70f7f67d

### Self-Managed Nodegroup
- **Stack Name**: `same-account-al2-nodes`
- **Node Group Name**: `customer1-al2-nodes`
- **Instance Type**: m5.large
- **Instance Count**: 2 (min: 1, max: 10)
- **AMI**: EKS-optimized Amazon Linux 2 for K8s 1.32
- **IAM Role**: `customer1-al2-nodes-role`
- **Security Group**: sg-04023bddd4620a376

### Running Nodes
```
NAME                                               STATUS   VERSION
ip-172-31-28-118.ap-southeast-2.compute.internal   Ready    v1.32.9-eks-ecaa3a6
ip-172-31-37-65.ap-southeast-2.compute.internal    Ready    v1.32.9-eks-ecaa3a6
```

## Key Learnings

### ❌ What Didn't Work

1. **Cross-Account Bottlerocket Nodes**
   - Issue: EKS authenticator can't query EC2 across accounts
   - Template: `{{EC2PrivateDNSName}}` fails for cross-account
   - Result: Username/hostname mismatch prevents node registration
   - **Solution**: Same-account deployment or different AMI

2. **Manual RHEL 9 Setup**
   - Issue: Complex manual kubelet/containerd installation
   - Result: CreationPolicy timeout (>15 minutes)
   - Too complex for quick deployment

### ✅ What Worked

1. **Amazon Linux 2 EKS-Optimized AMI**
   - Simple bootstrap: `/etc/eks/bootstrap.sh ${ClusterName}`
   - Pre-configured kubelet, containerd, CNI
   - Fast deployment (~5 minutes)
   - Proven and supported by AWS

2. **Security Group Configuration**
   - Critical: Cluster SG must allow inbound from node SG on port 443
   - Without this rule: nodes get "dial tcp ... i/o timeout"
   - With rule: nodes join within 30 seconds

3. **aws-auth ConfigMap**
   - Same-account nodes work perfectly with `{{EC2PrivateDNSName}}` template
   - Proper mapping:
     ```yaml
     - rolearn: arn:aws:iam::ACCOUNT:role/NodeRole
       username: system:node:{{EC2PrivateDNSName}}
       groups:
         - system:bootstrappers
         - system:nodes
     ```

## Files Created

### CloudFormation Templates
1. **`cfn/hub-cluster-with-cross-account-nodes.yaml`**
   - Hub EKS cluster for cross-account architecture
   - Authentication mode: API_AND_CONFIG_MAP

2. **`cfn/spoke-nodegroup-only.yaml`**
   - Cross-account nodegroup (Bottlerocket)
   - Status: Doesn't work due to authenticator limitation

3. **`cfn/same-account-nodegroup-al2.yaml`** ✅
   - **Working same-account nodegroup**
   - Amazon Linux 2 EKS-optimized AMI
   - Simple and fast deployment

4. **`cfn/same-account-nodegroup-rhel9.yaml`**
   - RHEL 9 with manual setup
   - Status: Too complex, times out

### Documentation
1. **`cfn/CROSS-ACCOUNT-LIMITATION.md`**
   - Detailed explanation of cross-account Bottlerocket limitation
   - Root cause analysis
   - Solutions and recommendations

2. **`DEPLOYMENT-SUCCESS.md`** (this file)
   - Summary of successful deployment
   - What worked and what didn't
   - Deployment guide

## Verification

### Test Workload Deployed Successfully
```bash
$ kubectl get pods -n customer1 -o wide
NAME                          READY   STATUS    RESTARTS   AGE   IP              NODE
nginx-test-76467dbfb5-5dd76   1/1     Running   0          20s   172.31.24.8     ip-172-31-28-118...
nginx-test-76467dbfb5-85jqr   1/1     Running   0          20s   172.31.40.225   ip-172-31-37-65...
nginx-test-76467dbfb5-8ckqs   1/1     Running   0          20s   172.31.40.13    ip-172-31-37-65...
```

### Node Labels Correct
```bash
$ kubectl get nodes --selector=customer=customer1
NAME                                               STATUS   ROLES    AGE     VERSION
ip-172-31-28-118.ap-southeast-2.compute.internal   Ready    <none>   5m30s   v1.32.9-eks-ecaa3a6
ip-172-31-37-65.ap-southeast-2.compute.internal    Ready    <none>   5m30s   v1.32.9-eks-ecaa3a6
```

## Quick Deployment Guide

### Prerequisites
- Existing EKS cluster
- VPC with subnets
- AWS CLI configured

### Deploy Steps

1. **Get cluster details**:
```bash
CLUSTER_NAME="hub-shared-cluster"
aws eks describe-cluster --name $CLUSTER_NAME --region ap-southeast-2
```

2. **Deploy nodegroup**:
```bash
aws cloudformation create-stack \
  --stack-name same-account-al2-nodes \
  --template-body file://cfn/same-account-nodegroup-al2.yaml \
  --parameters \
    ParameterKey=ClusterName,ParameterValue=$CLUSTER_NAME \
    ParameterKey=VpcId,ParameterValue=<VPC_ID> \
    ParameterKey=Subnet1Id,ParameterValue=<SUBNET_1> \
    ParameterKey=Subnet2Id,ParameterValue=<SUBNET_2> \
    ParameterKey=Subnet3Id,ParameterValue=<SUBNET_3> \
  --capabilities CAPABILITY_NAMED_IAM \
  --region ap-southeast-2
```

3. **Add security group rule** (CRITICAL):
```bash
CLUSTER_SG=$(aws eks describe-cluster --name $CLUSTER_NAME --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
NODE_SG=$(aws cloudformation describe-stacks --stack-name same-account-al2-nodes --query 'Stacks[0].Outputs[?OutputKey==`NodeSecurityGroupId`].OutputValue' --output text)

aws ec2 authorize-security-group-ingress \
  --group-id $CLUSTER_SG \
  --protocol tcp \
  --port 443 \
  --source-group $NODE_SG
```

4. **Add node role to aws-auth**:
```bash
NODE_ROLE=$(aws cloudformation describe-stacks --stack-name same-account-al2-nodes --query 'Stacks[0].Outputs[?OutputKey==`NodeRoleArn`].OutputValue' --output text)

kubectl edit configmap aws-auth -n kube-system
# Add under mapRoles:
# - rolearn: <NODE_ROLE_ARN>
#   username: system:node:{{EC2PrivateDNSName}}
#   groups:
#     - system:bootstrappers
#     - system:nodes
```

5. **Verify**:
```bash
kubectl get nodes
kubectl apply -f test-deployment.yaml
kubectl get pods -n customer1
```

## Cost Analysis

### Monthly Costs (ap-southeast-2)
- EKS Control Plane: $73.00
- 2x m5.large nodes: ~$0.116/hr × 2 × 730 hrs = ~$169/month
- EBS volumes: 2 × 50GB × $0.10/GB = ~$10/month
- **Total: ~$252/month**

### vs. Managed Node Groups
- Same cost for nodes
- Managed groups: easier updates, AWS-managed
- Self-managed: more control, custom AMIs, more configuration options

## Troubleshooting Tips

### Nodes Not Joining?

1. **Check security groups**:
   - Cluster SG MUST allow inbound from node SG on port 443
   - Without this: "dial tcp ... i/o timeout" errors

2. **Check aws-auth ConfigMap**:
   ```bash
   kubectl get configmap aws-auth -n kube-system -o yaml
   ```

3. **Check node logs**:
   ```bash
   # Via SSM
   aws ssm start-session --target <instance-id>
   sudo journalctl -u kubelet -f
   ```

4. **Check CloudWatch logs**:
   ```bash
   aws logs tail /aws/eks/<cluster-name>/cluster --since 10m
   ```

### Common Errors

**"Unable to register node"**:
- Security group issue (most common)
- Check node can reach cluster endpoint

**"access denied"**:
- aws-auth ConfigMap not configured
- Wrong IAM role ARN

**"context deadline exceeded"**:
- Network connectivity issue
- Check NAT Gateway or Internet Gateway
- Verify route tables

## Recommendations

### For Production
1. Use EKS-optimized Amazon Linux 2 (proven, supported)
2. Always add security group rules for cluster ↔ node communication
3. Use Auto Scaling Groups with proper health checks
4. Implement node labels for workload placement
5. Set up monitoring (CloudWatch, Prometheus)

### For Multi-Tenant
1. **Same-account multi-nodegroup**: Best for isolation within one account
2. **Separate clusters**: Best for true customer isolation
3. **Cross-account**: Currently problematic with Bottlerocket + aws-auth

### For Cost Optimization
1. Use spot instances in ASG (not shown in this template)
2. Implement cluster autoscaler
3. Right-size instance types
4. Use gp3 volumes instead of gp2

## Next Steps

1. ✅ Same-account self-managed nodes working
2. ⬜ Add cluster autoscaler
3. ⬜ Configure logging (FluentBit → CloudWatch)
4. ⬜ Set up monitoring (Prometheus → AMP)
5. ⬜ Implement RBAC per customer namespace
6. ⬜ Add more nodegroups for different customers
7. ⬜ Configure pod disruption budgets
8. ⬜ Set up backup strategy

## Cleanup

To remove everything:
```bash
# Delete test workload
kubectl delete -f test-deployment.yaml

# Delete nodegroup stack
aws cloudformation delete-stack --stack-name same-account-al2-nodes --region ap-southeast-2

# Delete cluster
aws cloudformation delete-stack --stack-name hub-eks-cluster --region ap-southeast-2
```

## Date
Deployed: 2026-06-30
Region: ap-southeast-2 (Sydney)
Kubernetes Version: 1.32
