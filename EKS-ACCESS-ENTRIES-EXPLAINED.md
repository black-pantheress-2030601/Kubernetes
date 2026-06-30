# EKS Access Entries - Deep Dive

## What Are EKS Access Entries?

EKS Access Entries are the **modern replacement** for the aws-auth ConfigMap. They provide IAM-to-Kubernetes RBAC mapping through an API instead of a ConfigMap.

**Two Methods to Grant Access:**

| Method | Created | Managed | Use Case |
|--------|---------|---------|----------|
| **aws-auth ConfigMap** | 2017 | kubectl edit | Legacy, manual |
| **EKS Access Entries** | 2023 | AWS API/CLI | Modern, automated |

Both solve the same problem: **"How do I map AWS IAM principals to Kubernetes users/groups?"**

## The Complete Authentication Flow

### Step 1: Node Boots and Gets AWS Credentials

```
┌─────────────────────────────────────────────────────────────┐
│ EC2 Instance (Spoke Account: 706863000784)                  │
│                                                              │
│ 1. Instance boots with IAM instance profile attached        │
│    - Instance Profile: "cross-account-customer1-profile"    │
│    - Attached Role: "cross-account-customer1-role"          │
│                                                              │
│ 2. Kubelet starts and needs cluster credentials             │
│    - Reads: /var/lib/kubelet/kubeconfig                     │
│    - Cluster endpoint in spoke account? NO                  │
│    - Cluster endpoint: https://HUB-CLUSTER.eks...           │
│                                                              │
│ 3. Kubelet needs to authenticate to hub cluster             │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Step 2: Kubelet Requests Kubernetes Token via AWS STS

```
┌─────────────────────────────────────────────────────────────┐
│ Kubelet Process                                              │
│                                                              │
│ 4. Kubelet runs: aws eks get-token --cluster-name ...       │
│                                                              │
│ 5. AWS SDK gets credentials from IMDS:                      │
│    - Queries: http://169.254.169.254/latest/meta-data/...   │
│    - Response:                                               │
│      {                                                       │
│        "Code": "Success",                                    │
│        "Type": "AWS-HMAC",                                   │
│        "AccessKeyId": "ASIA...",                             │
│        "SecretAccessKey": "...",                             │
│        "Token": "...",                                       │
│        "Expiration": "..."                                   │
│      }                                                       │
│                                                              │
│ 6. AWS SDK extracts identity from IMDS:                     │
│    - Account: 706863000784 (spoke account)                  │
│    - Role: cross-account-customer1-role                     │
│    - Instance ID: i-0572ee23a09f5b86e                       │
│                                                              │
│ 7. Creates STS GetCallerIdentity presigned URL:             │
│    - Method: GET                                             │
│    - Service: sts                                            │
│    - Action: GetCallerIdentity                              │
│    - Signed with: spoke account credentials                 │
│    - Encodes as base64 token                                │
│                                                              │
│ 8. Returns token to kubelet:                                │
│    {                                                         │
│      "kind": "ExecCredential",                              │
│      "apiVersion": "client.authentication.k8s.io/v1beta1",  │
│      "spec": {},                                             │
│      "status": {                                             │
│        "token": "k8s-aws-v1.aHR0cHM6Ly9zdHMuYW1hem..."      │
│      }                                                       │
│    }                                                         │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

**What's in the token?**
- It's a base64-encoded presigned STS URL
- Decoded: `https://sts.amazonaws.com/?Action=GetCallerIdentity&X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=ASIA.../20260630/us-east-1/sts/aws4_request&X-Amz-SignedHeaders=...`
- The signature proves: "I am IAM role X in account Y"

### Step 3: Kubelet Makes API Request to EKS Control Plane

```
┌─────────────────────────────────────────────────────────────┐
│ Kubelet → EKS API Server                                     │
│                                                              │
│ 9. Kubelet makes request:                                    │
│    GET https://HUB-CLUSTER.eks.amazonaws.com/api/v1/nodes   │
│                                                              │
│ 10. Headers:                                                 │
│     Authorization: Bearer k8s-aws-v1.aHR0cHM6Ly9...          │
│                                                              │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│ EKS Control Plane (Hub Account: 969341426174)               │
│                                                              │
│ 11. Request arrives at API server                           │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Step 4: EKS IAM Authenticator Processes the Token

```
┌─────────────────────────────────────────────────────────────┐
│ AWS IAM Authenticator (runs in EKS control plane)           │
│                                                              │
│ 12. Extracts token from Authorization header                │
│     - Removes "k8s-aws-v1." prefix                          │
│     - Base64 decodes the presigned URL                      │
│                                                              │
│ 13. Calls the presigned STS URL:                            │
│     GET https://sts.amazonaws.com/?Action=GetCallerIdentity  │
│     (with all the signature parameters)                     │
│                                                              │
│ 14. STS Response:                                            │
│     {                                                        │
│       "GetCallerIdentityResponse": {                        │
│         "GetCallerIdentityResult": {                        │
│           "Account": "706863000784",                        │
│           "UserId": "AROA...:i-0572ee23a09f5b86e",          │
│           "Arn": "arn:aws:sts::706863000784:assumed-role/   │
│                   cross-account-customer1-role/              │
│                   i-0572ee23a09f5b86e"                      │
│         }                                                    │
│       }                                                      │
│     }                                                        │
│                                                              │
│ 15. Authenticator extracts identity:                        │
│     - Account: 706863000784 ✓                               │
│     - Role: cross-account-customer1-role ✓                  │
│     - Session Name: i-0572ee23a09f5b86e ✓                   │
│     - Principal ARN: arn:aws:iam::706863000784:role/...     │
│                                                              │
│ ✅ AUTHENTICATION SUCCESSFUL                                 │
│    The token is valid and represents a real AWS identity    │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

**Key Point:** Authentication **SUCCEEDS** even cross-account! STS validates the signature regardless of which account the cluster is in.

### Step 5: EKS Access Entry Lookup (Authorization)

Now the authenticator needs to convert AWS identity → Kubernetes user/groups.

```
┌─────────────────────────────────────────────────────────────┐
│ EKS Access Entry Lookup                                      │
│                                                              │
│ 16. Check cluster authentication mode:                      │
│     - API_AND_CONFIG_MAP                                     │
│     - Try both methods                                       │
│                                                              │
│ 17. METHOD 1: Check EKS Access Entries                      │
│                                                              │
│     Query: List all access entries for this cluster         │
│                                                              │
│     aws eks list-access-entries \                           │
│       --cluster-name hub-shared-cluster                     │
│                                                              │
│     Response:                                                │
│     [                                                        │
│       "arn:aws:iam::969341426174:role/same-account-role",   │
│       (no entries from account 706863000784)                │
│     ]                                                        │
│                                                              │
│     ❌ NO MATCH FOUND                                        │
│                                                              │
│     Why? Access entries can only be created for:            │
│     - Same account principals (for EC2_LINUX type)          │
│     - Cross-account only for STANDARD type (human users)    │
│                                                              │
│     We tried to create:                                      │
│     aws eks create-access-entry \                           │
│       --principal-arn arn:aws:iam::706863000784:role/...    │
│       --type EC2_LINUX                                       │
│                                                              │
│     Error: "AccessEntry principalArn must be from the       │
│             same account as the cluster when using          │
│             types [EC2_LINUX, EC2_WINDOWS, ...]"            │
│                                                              │
│ 18. METHOD 2: Check aws-auth ConfigMap                      │
│                                                              │
│     Query: kubectl get configmap aws-auth -n kube-system    │
│                                                              │
│     ConfigMap data:                                          │
│     mapRoles: |                                              │
│       - rolearn: arn:aws:iam::706863000784:role/            │
│                  cross-account-customer1-role               │
│         username: system:node:{{EC2PrivateDNSName}}         │
│         groups:                                              │
│           - system:bootstrappers                             │
│           - system:nodes                                     │
│                                                              │
│     ✅ MATCH FOUND!                                          │
│                                                              │
│     Now need to resolve: {{EC2PrivateDNSName}}              │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Step 6: Template Variable Substitution (THE FAILURE POINT)

```
┌─────────────────────────────────────────────────────────────┐
│ Template Variable Resolution                                 │
│                                                              │
│ 19. Authenticator needs to resolve:                         │
│     username: system:node:{{EC2PrivateDNSName}}             │
│                                                              │
│     Available variables from STS response:                   │
│     - {{AccountID}} = 706863000784                          │
│     - {{SessionName}} = i-0572ee23a09f5b86e                 │
│     - {{PrincipalArn}} = arn:aws:sts::706863000784:...      │
│                                                              │
│     Not available: EC2PrivateDNSName                        │
│                                                              │
│ 20. To resolve {{EC2PrivateDNSName}}:                       │
│                                                              │
│     Authenticator calls EC2 API:                             │
│                                                              │
│     aws ec2 describe-instances \                            │
│       --instance-ids i-0572ee23a09f5b86e \                  │
│       --query 'Reservations[0].Instances[0].                │
│                PrivateDnsName'                              │
│                                                              │
│     ❌ ERROR!                                                │
│                                                              │
│     Error Response:                                          │
│     {                                                        │
│       "Error": {                                             │
│         "Code": "InvalidInstanceID.NotFound",               │
│         "Message": "The instance ID 'i-0572ee23a09f5b86e'   │
│                     does not exist"                         │
│       }                                                      │
│     }                                                        │
│                                                              │
│     WHY IT FAILS:                                            │
│     - EC2 API called from: Hub account (969341426174)       │
│     - Instance exists in: Spoke account (706863000784)      │
│     - No cross-account describe permissions                 │
│     - Even if we added permissions, API would need          │
│       --profile or AssumeRole                               │
│     - Authenticator doesn't support cross-account EC2       │
│                                                              │
│ 21. Fallback: Use SessionName as username                   │
│                                                              │
│     Since {{EC2PrivateDNSName}} failed to resolve:          │
│     username = system:node:i-0572ee23a09f5b86e              │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Step 7: Kubernetes RBAC Check

```
┌─────────────────────────────────────────────────────────────┐
│ Kubernetes Authorization (RBAC)                              │
│                                                              │
│ 22. Identity assigned:                                       │
│     - Username: system:node:i-0572ee23a09f5b86e             │
│     - Groups: [system:bootstrappers, system:nodes]          │
│                                                              │
│ 23. Node tries to register:                                 │
│     - Node name: ip-172-31-28-238.compute.internal          │
│     - Action: nodes.create                                   │
│                                                              │
│ 24. RBAC evaluation:                                         │
│                                                              │
│     Check: Can user "system:node:i-0572ee23a09f5b86e"       │
│            create node "ip-172-31-28-238.compute..."?       │
│                                                              │
│     ClusterRoleBinding: system:node                         │
│     - Binds: system:nodes group                             │
│     - To: system:node ClusterRole                           │
│                                                              │
│     ClusterRole: system:node                                │
│     - Rules:                                                 │
│       apiGroups: [""]                                        │
│       resources: ["nodes"]                                   │
│       verbs: ["get", "list", "watch", "create", "update"]   │
│       resourceNames: ["{{nodeName}}"]  ← CRITICAL!          │
│                                                              │
│     WHERE {{nodeName}} is extracted from username:          │
│     - Username: system:node:i-0572ee23a09f5b86e             │
│     - Extracted nodeName: i-0572ee23a09f5b86e               │
│                                                              │
│ 25. RBAC Decision:                                           │
│                                                              │
│     Question: Can node "i-0572ee23a09f5b86e"                │
│               manage node "ip-172-31-28-238.compute..."?    │
│                                                              │
│     ❌ NO - Resource name mismatch!                          │
│                                                              │
│     - Allowed resource name: i-0572ee23a09f5b86e            │
│     - Requested resource name: ip-172-31-28-238.compute...  │
│                                                              │
│     These don't match!                                       │
│                                                              │
│ 26. Error returned to kubelet:                              │
│                                                              │
│     "nodes 'ip-172-31-28-238.compute.internal' is           │
│      forbidden: User 'system:node:i-0572ee23a09f5b86e'      │
│      cannot get resource 'nodes' at the cluster scope:      │
│      node 'i-0572ee23a09f5b86e' cannot read                 │
│      'ip-172-31-28-238.compute.internal',                   │
│      only its own Node object"                              │
│                                                              │
│ ❌ AUTHORIZATION FAILED                                      │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Step 8: Kubelet Retry Loop

```
┌─────────────────────────────────────────────────────────────┐
│ Kubelet Behavior                                             │
│                                                              │
│ 27. Kubelet receives 403 Forbidden                          │
│                                                              │
│ 28. Logs error and retries every 7 seconds:                 │
│     "Unable to register node with API server"               │
│                                                              │
│ 29. Node never joins cluster                                │
│     - kubectl get nodes → not listed                        │
│     - Instance keeps running but useless                    │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## Visual Summary of the Complete Flow

```
┌──────────────────────────────────────────────────────────────────────┐
│                         SPOKE ACCOUNT                                │
│                                                                       │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ EC2 Instance: i-0572ee23a09f5b86e                           │   │
│  │ Hostname: ip-172-31-28-238.compute.internal                 │   │
│  │ IAM Role: cross-account-customer1-role                      │   │
│  │                                                              │   │
│  │ Kubelet: "I need to join the cluster..."                    │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                          │                                            │
│                          │ 1. Get credentials from IMDS              │
│                          │ 2. Call aws eks get-token                 │
│                          │ 3. Generate presigned STS URL              │
│                          ▼                                            │
│                    [STS Token]                                        │
│                          │                                            │
└──────────────────────────┼───────────────────────────────────────────┘
                           │
                           │ 4. API Request with token
                           ▼
┌──────────────────────────────────────────────────────────────────────┐
│                         HUB ACCOUNT                                  │
│                                                                       │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │ EKS Control Plane: hub-shared-cluster                        │  │
│  │                                                               │  │
│  │ 5. Validate token via STS                                    │  │
│  │    ✅ Identity: spoke-account-role                           │  │
│  │                                                               │  │
│  │ 6. Look up Access Entries                                    │  │
│  │    ❌ Not found (cross-account EC2_LINUX not allowed)       │  │
│  │                                                               │  │
│  │ 7. Check aws-auth ConfigMap                                  │  │
│  │    ✅ Found: role with {{EC2PrivateDNSName}} template       │  │
│  │                                                               │  │
│  │ 8. Try to resolve {{EC2PrivateDNSName}}                     │  │
│  │    ├─ Call EC2 API: describe-instances                      │  │
│  │    └─ ❌ Instance not found (wrong account)                 │  │
│  │                                                               │  │
│  │ 9. Fallback to instance ID as username                       │  │
│  │    Username: system:node:i-0572ee23a09f5b86e                │  │
│  │                                                               │  │
│  │ 10. RBAC Check                                               │  │
│  │     User: i-0572ee23a09f5b86e                               │  │
│  │     Wants to manage: ip-172-31-28-238.compute.internal      │  │
│  │     ❌ MISMATCH - DENIED                                     │  │
│  │                                                               │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                                                                       │
└───────────────────────────────────────────────────────────────────────┘
```

## Why Access Entries Can't Fix This

**The Restriction:**
```bash
$ aws eks create-access-entry \
    --principal-arn arn:aws:iam::706863000784:role/node-role \
    --type EC2_LINUX

Error: AccessEntry principalArn must be from the same account 
       as the cluster when using types [EC2_LINUX, ...]
```

**Why AWS Enforces This:**

1. **EC2 Metadata Assumption**: `EC2_LINUX` type assumes the principal has EC2 instances **in the same account** where authenticator can query metadata

2. **Template Variables**: Templates like `{{EC2PrivateDNSName}}` require EC2 API access in the principal's account

3. **Security Model**: Prevents accidentally granting access to cross-account EC2 instances without explicit permissions

**Types That Allow Cross-Account:**

| Type | Cross-Account? | Use Case |
|------|----------------|----------|
| `STANDARD` | ✅ Yes | Human users, CI/CD roles |
| `EC2_LINUX` | ❌ No | EC2 worker nodes |
| `EC2_WINDOWS` | ❌ No | Windows worker nodes |
| `FARGATE_LINUX` | ❌ No | Fargate pods |
| `HYBRID_LINUX` | ❓ Unknown | Hybrid/edge nodes |

## How Hybrid Nodes Would Be Different

With `HYBRID_LINUX` access entries:

```
┌──────────────────────────────────────────────────────────────┐
│ SPOKE ACCOUNT - EC2 Instance (as hybrid node)                │
│                                                               │
│ 1. Has X.509 certificate (not instance profile)             │
│ 2. Runs aws_signing_helper to get credentials:              │
│    - Assumes role in HUB account via IAM Roles Anywhere     │
│    - Role: arn:aws:iam::HUB:role/hybrid-node-role           │
│                                                               │
│ 3. Kubelet uses HUB account credentials                      │
│                                                               │
└──────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────────────────┐
│ HUB ACCOUNT - EKS Control Plane                              │
│                                                               │
│ 4. Validate token via STS                                    │
│    ✅ Identity: HUB account role (same account!)            │
│                                                               │
│ 5. Look up HYBRID_LINUX Access Entry                         │
│    ✅ Found: arn:aws:iam::HUB:role/hybrid-node-role         │
│    Username: system:node:{{SessionName}}                     │
│                                                               │
│ 6. No EC2 API query needed!                                  │
│    SessionName from certificate: customer1-node-001          │
│                                                               │
│ 7. RBAC Check                                                 │
│    User: system:node:customer1-node-001                      │
│    Manages: customer1-node-001                               │
│    ✅ MATCH - ALLOWED                                        │
│                                                               │
└──────────────────────────────────────────────────────────────┘
```

**Key Differences:**
- ✅ No EC2 metadata dependency
- ✅ Same-account principal (via IAM Roles Anywhere)
- ✅ Custom node name (matches username)
- ✅ No template variable resolution needed

## Summary

**The Problem:**
Cross-account EC2 nodes fail because:
1. ✅ **Authentication works** - STS validates the identity
2. ❌ **Authorization fails** - EC2PrivateDNSName template can't be resolved cross-account
3. ❌ **RBAC denies** - username (instance ID) doesn't match node name (hostname)

**Why Access Entries Don't Help:**
- `EC2_LINUX` type explicitly blocks cross-account principals
- Designed assuming EC2 instances in same account as cluster
- No cross-account EC2 API query support in authenticator

**Potential Solution (Hybrid Nodes):**
- Use certificates instead of instance profiles
- Assume hub account role via IAM Roles Anywhere
- `HYBRID_LINUX` access entry type (may allow cross-account)
- No EC2 API dependency

**Current Recommended Solution:**
- Separate complete EKS clusters per account
- No cross-account authentication complexity
- Standard, supported, proven pattern
