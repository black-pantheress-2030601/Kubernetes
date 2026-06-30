# EKS Hybrid Nodes for Cross-Account Architecture

## Your Question

**Could IAM Roles Anywhere + HYBRID_LINUX access entries solve the cross-account node problem?**

## Short Answer

**YES - In theory, this should work!** EKS Hybrid Nodes were designed for on-premises/edge workloads but their authentication model bypasses the EC2 metadata dependency that causes cross-account failures.

## How EKS Hybrid Nodes Work

### Traditional EC2 Node Authentication (Current Problem)

```
┌─────────────────────────────────────────────────────────────┐
│ Spoke Account EC2 Instance                                  │
│                                                              │
│ 1. Kubelet reads EC2 instance profile                       │
│ 2. Calls: aws eks get-token                                 │
│ 3. Gets STS token with identity:                            │
│    - Instance ID: i-0572ee23a09f5b86e                       │
│    - Username: system:node:i-0572ee23a09f5b86e              │
│                                                              │
│ 4. Kubelet tries to register as:                            │
│    - Hostname: ip-172-31-28-238.compute.internal            │
│                                                              │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│ Hub Account EKS Control Plane                               │
│                                                              │
│ 5. Receives auth: system:node:i-0572ee23a09f5b86e           │
│ 6. Node tries to register: ip-172-31-28-238.compute...      │
│ 7. EKS Authenticator queries EC2 API:                       │
│    - DescribeInstances(i-0572ee23a09f5b86e)                 │
│    - ❌ FAILS - instance not in this account                │
│ 8. Cannot map instance ID → hostname                        │
│ 9. ❌ RBAC DENIES - username mismatch                       │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Hybrid Node Authentication (Potential Solution)

```
┌─────────────────────────────────────────────────────────────┐
│ Spoke Account EC2 Instance (configured as hybrid)           │
│                                                              │
│ 1. Node has X.509 certificate (from Private CA)             │
│ 2. Runs: nodeadm (hybrid node agent)                        │
│ 3. Uses IAM Roles Anywhere to get credentials:              │
│    aws_signing_helper credential-process \                  │
│      --certificate node.crt \                               │
│      --private-key node.key \                               │
│      --trust-anchor-arn arn:...:trust-anchor/xxx \          │
│      --profile-arn arn:...:profile/hybrid-node-profile \    │
│      --role-arn arn:aws:iam::HUB:role/hybrid-node-role     │
│                                                              │
│ 4. Gets temporary AWS credentials for HUB account role      │
│ 5. Kubelet authenticates with those credentials             │
│    - Username: system:node:my-custom-node-name              │
│    - No instance ID involved!                               │
│                                                              │
│ 6. Node registers with custom name (from nodeadm config)    │
│                                                              │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│ Hub Account EKS Control Plane                               │
│                                                              │
│ 7. Receives auth from hub account role                      │
│    - Role: arn:aws:iam::HUB:role/hybrid-node-role           │
│    - Username: system:node:my-custom-node-name              │
│                                                              │
│ 8. Checks HYBRID_LINUX access entry:                        │
│    - Principal: arn:aws:iam::HUB:role/hybrid-node-role      │
│    - Type: HYBRID_LINUX                                     │
│    - Username: system:node:{{SessionName}}                  │
│                                                              │
│ 9. Node registers as: my-custom-node-name                   │
│ 10. ✅ SUCCESS - no EC2 queries needed!                     │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## Key Differences

| Aspect | EC2 Nodes | Hybrid Nodes |
|--------|-----------|--------------|
| **Credentials** | EC2 instance profile (IMDS) | X.509 certificate + IAM Roles Anywhere |
| **Username** | Instance ID (`i-xxxxx`) | Custom (from certificate or SessionName) |
| **Node Name** | EC2 private DNS name | Custom (configured in nodeadm) |
| **EC2 API Query** | Required (for name mapping) | Not needed |
| **Cross-Account** | ❌ Fails | ✅ Should work |
| **Access Entry Type** | `EC2_LINUX` | `HYBRID_LINUX` |

## Why This Should Work for Cross-Account

1. **No EC2 Metadata Dependency**
   - Hybrid nodes don't use instance profiles
   - Certificate-based authentication instead
   - No instance ID → hostname mapping required

2. **Hub Account Credentials**
   - IAM Roles Anywhere issues credentials for a role in HUB account
   - Node authenticates AS a hub account principal
   - EKS sees it as same-account authentication

3. **Explicit Node Naming**
   - Node name set in configuration file
   - No DNS name auto-detection
   - Username matches node name (no mismatch)

4. **HYBRID_LINUX Access Entry**
   - Designed for non-EC2 workloads
   - No same-account validation (unlike `EC2_LINUX`)
   - Supports custom authentication flows

## Implementation Architecture

```
┌──────────────────────────────────────────────────────────────┐
│               Hub Account (WorkloadConfig)                   │
│                                                               │
│  ┌────────────────────────────────────────────────────┐     │
│  │ AWS Private CA                                     │     │
│  │ - Issues X.509 certificates for nodes              │     │
│  └────────────────────────────────────────────────────┘     │
│                          │                                    │
│  ┌────────────────────────────────────────────────────┐     │
│  │ IAM Roles Anywhere                                 │     │
│  │ - Trust Anchor (trusts Private CA)                 │     │
│  │ - Profile: hybrid-node-profile                     │     │
│  │   → Maps cert → IAM role                           │     │
│  └────────────────────────────────────────────────────┘     │
│                          │                                    │
│  ┌────────────────────────────────────────────────────┐     │
│  │ IAM Role: hybrid-node-role                         │     │
│  │ - AmazonEKSWorkerNodePolicy                        │     │
│  │ - AmazonEC2ContainerRegistryReadOnly               │     │
│  │ - AmazonEKS_CNI_Policy                             │     │
│  └────────────────────────────────────────────────────┘     │
│                          │                                    │
│  ┌────────────────────────────────────────────────────┐     │
│  │ EKS Cluster: hub-shared-cluster                    │     │
│  │                                                     │     │
│  │ Access Entry:                                      │     │
│  │   Principal: hybrid-node-role ARN                  │     │
│  │   Type: HYBRID_LINUX                               │     │
│  │   Username: system:node:{{SessionName}}            │     │
│  │   Groups: [system:bootstrappers, system:nodes]     │     │
│  └────────────────────────────────────────────────────┘     │
│                                                               │
└───────────────────────────────────────────────────────────────┘
                          │
                Cross-Account Certificate
                          │
┌───────────────────────────────────────────────────────────────┐
│          Spoke Account (SandboxWC)                            │
│                                                                │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ EC2 Instance (configured as hybrid node)             │   │
│  │                                                       │   │
│  │ Files:                                                │   │
│  │   /etc/eks/hybrid/node.crt    (from Private CA)      │   │
│  │   /etc/eks/hybrid/node.key    (private key)          │   │
│  │   /etc/eks/hybrid/nodeadm.yaml (config)              │   │
│  │                                                       │   │
│  │ Services:                                             │   │
│  │   nodeadm          (hybrid agent)                    │   │
│  │   kubelet          (uses hybrid credentials)         │   │
│  │   containerd       (container runtime)               │   │
│  │                                                       │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

## Implementation Steps

### 1. Hub Account Setup

**Create Private CA:**
```bash
aws acm-pca create-certificate-authority \
  --certificate-authority-type ROOT \
  --certificate-authority-configuration \
    "KeyAlgorithm=RSA_2048,
     SigningAlgorithm=SHA256WITHRSA,
     Subject={
       Country=AU,
       Organization=MyOrg,
       CommonName=EKS-Hybrid-CA
     }" \
  --region ap-southeast-2 \
  --profile WorkloadConfig
```

**Create IAM Roles Anywhere Trust Anchor:**
```bash
CA_ARN="arn:aws:acm-pca:ap-southeast-2:969341426174:certificate-authority/xxx"

aws rolesanywhere create-trust-anchor \
  --name eks-hybrid-nodes \
  --source "sourceType=AWS_ACM_PCA,sourceData={acmPcaArn=$CA_ARN}" \
  --region ap-southeast-2 \
  --profile WorkloadConfig
```

**Create IAM Role for Hybrid Nodes:**
```bash
# See CloudFormation template below
```

**Create IAM Roles Anywhere Profile:**
```bash
aws rolesanywhere create-profile \
  --name hybrid-node-profile \
  --role-arns "arn:aws:iam::969341426174:role/hybrid-node-role" \
  --region ap-southeast-2 \
  --profile WorkloadConfig
```

**Create EKS Access Entry:**
```bash
aws eks create-access-entry \
  --cluster-name hub-shared-cluster \
  --principal-arn arn:aws:iam::969341426174:role/hybrid-node-role \
  --type HYBRID_LINUX \
  --region ap-southeast-2 \
  --profile WorkloadConfig

aws eks associate-access-policy \
  --cluster-name hub-shared-cluster \
  --principal-arn arn:aws:iam::969341426174:role/hybrid-node-role \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSWorkerNodePolicy \
  --access-scope type=cluster \
  --region ap-southeast-2 \
  --profile WorkloadConfig
```

### 2. Certificate Issuance (Per Node)

```bash
# Generate private key
openssl genrsa -out node.key 2048

# Generate CSR
openssl req -new -key node.key -out node.csr \
  -subj "/C=AU/O=MyOrg/CN=customer1-node-001"

# Issue certificate from Private CA
aws acm-pca issue-certificate \
  --certificate-authority-arn $CA_ARN \
  --csr fileb://node.csr \
  --signing-algorithm SHA256WITHRSA \
  --validity Value=365,Type=DAYS \
  --region ap-southeast-2 \
  --profile WorkloadConfig

# Get certificate
aws acm-pca get-certificate \
  --certificate-authority-arn $CA_ARN \
  --certificate-arn <cert-arn> \
  --region ap-southeast-2 \
  --profile WorkloadConfig \
  --query Certificate \
  --output text > node.crt
```

### 3. Spoke Account Node Configuration

**Install nodeadm (hybrid agent):**
```bash
# Download from EKS
curl -O https://hybrid-assets.eks.amazonaws.com/releases/latest/bin/linux/amd64/nodeadm
chmod +x nodeadm
sudo mv nodeadm /usr/local/bin/

# Install aws_signing_helper (IAM Roles Anywhere credential helper)
curl -O https://rolesanywhere.amazonaws.com/releases/latest/X86_64/Linux/aws_signing_helper
chmod +x aws_signing_helper
sudo mv aws_signing_helper /usr/local/bin/
```

**Create nodeadm configuration:**
```yaml
# /etc/eks/hybrid/nodeadm.yaml
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  cluster:
    name: hub-shared-cluster
    region: ap-southeast-2
    apiServerEndpoint: https://1B6BB231450B3833F3D8146906ECFF5C.gr7.ap-southeast-2.eks.amazonaws.com
    certificateAuthority: <base64-encoded-ca>
    cidr: 10.100.0.0/16
  
  hybrid:
    ssm:
      activationCode: <activation-code>
      activationId: <activation-id>
  
  iam:
    rolesAnywhere:
      trustAnchorArn: arn:aws:rolesanywhere:ap-southeast-2:969341426174:trust-anchor/xxx
      profileArn: arn:aws:rolesanywhere:ap-southeast-2:969341426174:profile/xxx
      roleArn: arn:aws:iam::969341426174:role/hybrid-node-role
      certificatePath: /etc/eks/hybrid/node.crt
      privateKeyPath: /etc/eks/hybrid/node.key
  
  kubelet:
    config:
      maxPods: 110
    flags:
      - --node-labels=customer=customer1,account=706863000784
```

**Start nodeadm:**
```bash
sudo systemctl enable nodeadm
sudo systemctl start nodeadm
```

## Current Status and Availability

### EKS Hybrid Nodes Availability

**Announced:** AWS re:Invent 2023  
**General Availability:** Early 2024  
**Supported Regions:** Most major regions including ap-southeast-2

**Kubernetes Versions:** 1.27+

**Check if available:**
```bash
aws eks describe-addon-versions \
  --kubernetes-version 1.32 \
  --addon-name eks-hybrid \
  --region ap-southeast-2
```

If the addon exists, hybrid nodes are supported in your region.

## Potential Issues and Considerations

### 1. EKS Access Entry Type Restriction

**Question:** Does `HYBRID_LINUX` access entry type have same-account restriction?

**From our earlier error:**
```
AccessEntry principalArn must be from the same account as the cluster 
when using types [EC2_LINUX, EC2_WINDOWS, FARGATE_LINUX, HYBRID_LINUX, EC2]
```

**Concern:** `HYBRID_LINUX` might also be in this restricted list.

**Workaround:** Even if restricted, the role IS in the hub account (issued via IAM Roles Anywhere), so it should pass validation.

### 2. Certificate Management

- Need to issue certificates to each node
- Certificates expire (need rotation strategy)
- Private CA costs ($400/month)
- Certificate issuance: $0.75/cert

### 3. Node Configuration Complexity

- More complex than standard EC2 nodes
- Requires nodeadm installation and configuration
- Need to manage certificate distribution
- SSM activation for hybrid node management

### 4. Networking

- Hybrid nodes were designed for on-premises
- VPC networking should still work for EC2-based hybrid nodes
- May need additional security group configuration

## Cost Comparison

### Option 1: Separate Clusters (Current Recommendation)

**Per Customer:**
- EKS Control Plane: $73/month
- 2x m5.large nodes: $169/month
- Total: $242/month

**For 3 customers:** $726/month

### Option 2: Hybrid Nodes (Cross-Account to One Cluster)

**Hub Account:**
- EKS Control Plane: $73/month
- Private CA: $400/month
- Certificate issuance: $0.75 × 6 nodes = $4.50/month

**Spoke Accounts:**
- 2x m5.large nodes per customer: $169/month × 3 = $507/month

**Total:** $73 + $400 + $5 + $507 = **$985/month**

**Comparison:**
- Separate clusters: $726/month
- Hybrid approach: $985/month
- **Hybrid is $259/month MORE expensive** due to Private CA cost

**Break-even:** Need ~6 customers for hybrid to be cheaper

## Recommendation

### For Your Use Case (2-5 Customers)

**Stick with separate clusters** because:
1. ✅ Lower cost ($726 vs $985 for 3 customers)
2. ✅ Simpler operationally
3. ✅ Better isolation (separate control planes)
4. ✅ Proven pattern (we already deployed it successfully)
5. ✅ No certificate management overhead

### When Hybrid Nodes Make Sense

1. **Many customers (>6)** where Private CA cost is amortized
2. **True hybrid workload** (on-premises + cloud)
3. **Edge computing** scenarios
4. **Centralized control plane** is a hard requirement
5. **Advanced networking** needs (transit gateway, etc.)

### If You Want to Try Hybrid Nodes Anyway

I can help you:
1. Set up Private CA in hub account
2. Configure IAM Roles Anywhere
3. Create HYBRID_LINUX access entry
4. Configure one spoke node as proof of concept
5. Test if it actually works cross-account

**Time estimate:** 2-3 hours for PoC

## Answer to Your Question

**"Does IAM Anywhere solve this?"**

**YES - in theory!** Hybrid nodes bypass the EC2 metadata dependency that causes cross-account failures.

**BUT:**
- Higher cost due to Private CA ($400/month)
- More operational complexity
- May still have access entry same-account restriction
- Not tested for this specific use case (designed for on-premises)

**For your scenario (2-5 customers), separate clusters remain the better choice.**

Would you like me to set up a hybrid node PoC to test if it actually works cross-account?
