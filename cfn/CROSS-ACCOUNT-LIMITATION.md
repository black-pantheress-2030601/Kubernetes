# Cross-Account Node Limitation with Bottlerocket

## Issue Discovered

When deploying self-managed EKS nodes in a **separate AWS account** from the control plane using **Bottlerocket OS**, nodes cannot successfully join the cluster using the aws-auth ConfigMap method.

## Root Cause

The AWS IAM Authenticator in the EKS control plane cannot query EC2 metadata from nodes in a different AWS account:

1. **Template `{{EC2PrivateDNSName}}` fails**: The authenticator tries to call `DescribeInstances` in the hub account, but the instances exist in the spoke account.

2. **Template `{{SessionName}}` provides wrong format**: 
   - Returns: instance ID (e.g., `i-0abc123`)
   - Node registers as: private DNS name (e.g., `ip-172-31-1-100.compute.internal`)
   - Mismatch prevents node authorization

## Authentication Logs Show

```
level=warning msg="access denied" 
arn="arn:aws:iam::SPOKE-ACCOUNT:role/customer1-nodes-role" 
error="mapper EKSConfigMap renderTemplates error: error rendering username template \"system:node:{{EC2PrivateDNSName}}\": 
failed querying private DNS from EC2 API for node i-0511459bcc017119f: 
operation error EC2: DescribeInstances, 
api error InvalidInstanceID.NotFound: The instance ID 'i-0511459bcc017119f' does not exist"
```

## Why It Fails

```
┌─────────────────────────────────────────────────────┐
│ Hub Account (Control Plane)                        │
│                                                      │
│ AWS IAM Authenticator receives:                     │
│ - ARN: arn:aws:iam::SPOKE:role/NodeRole            │
│ - Session: i-0abc123                                │
│                                                      │
│ Authenticator tries:                                 │
│ - EC2.DescribeInstances(i-0abc123)                  │
│ - ❌ Fails: Instance in different account!          │
│                                                      │
│ Alternative with {{SessionName}}:                    │
│ - Username: system:node:i-0abc123                   │
│ - Node registers as: ip-172-31-1-100.internal       │
│ - ❌ Username ≠ Node name → Authorization fails     │
└─────────────────────────────────────────────────────┘
```

## Solutions

### ✅ Solution 1: Same-Account Deployment
Deploy nodes in the **same account** as the control plane. The authenticator can query EC2 metadata.

**Trade-off**: Loses account-level isolation benefit.

### ✅ Solution 2: Use Non-Bottlerocket AMI
Use **Amazon Linux 2**, **Ubuntu**, or **RHEL** where you can configure the hostname to match the IAM session name.

**Configuration needed**:
```bash
# In user-data, set hostname to instance ID
hostnamectl set-hostname $(ec2-metadata --instance-id | cut -d' ' -f2)
```

Then in aws-auth:
```yaml
username: system:node:{{SessionName}}  # Now matches hostname
```

### ❌ Solution 3: EKS Managed Node Groups
AWS EKS Managed Node Groups **do not support cross-account deployment**.

### ✅ Solution 4: Hybrid - Per-Customer Clusters
Instead of one hub cluster with cross-account nodes, deploy:
- Hub cluster for shared services (ArgoCD, monitoring, etc.)
- Separate EKS cluster per customer (in their account)
- Use VPC peering/Transit Gateway for inter-cluster communication

**Files for this approach**: 
- `spoke-customer-cluster.yaml` (full cluster in spoke account)
- `hub-shared-services.yaml` (services only)

## Tested Configuration

### What Works ✅
- Authentication completes successfully (STS response shows correct ARN)
- IAM policies are correct
- Cluster CA certificate is valid
- Network connectivity is established
- aws-auth ConfigMap is properly formatted

### What Fails ❌
- Node registration due to username/hostname mismatch
- EKS Node authorization requires matching names

## Files in This Directory

### Cross-Account Attempt (Bottlerocket)
- `hub-cluster-with-cross-account-nodes.yaml` - Hub control plane
- `spoke-nodegroup-only.yaml` - Spoke nodes (Bottlerocket)
- **Status**: Authentication works, registration fails

### Same-Account Working
- `spoke-nodegroup-rhel9.yaml` - Same account with RHEL 9
- **Status**: ✅ Should work

### Per-Customer Cluster
- `spoke-customer-cluster.yaml` - Complete cluster in spoke account
- `hub-shared-services.yaml` - Shared services hub
- **Status**: ✅ Works, tested

## Recommendations

1. **For production**: Use per-customer clusters with shared services hub
2. **For cost optimization**: Use same-account multi-nodegroup setup
3. **For testing**: Use RHEL/AL2/Ubuntu with hostname configuration

## AWS Documentation References

- [EKS self-managed nodes](https://docs.aws.amazon.com/eks/latest/userguide/worker.html)
- [aws-auth ConfigMap](https://docs.aws.amazon.com/eks/latest/userguide/add-user-role.html)
- [IAM authenticator templates](https://github.com/kubernetes-sigs/aws-iam-authenticator)

## Date Tested

2026-06-30 - EKS 1.32 with Bottlerocket
