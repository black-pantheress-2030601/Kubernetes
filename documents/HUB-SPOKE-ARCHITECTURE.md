# Hub-and-Spoke Multi-Cluster Architecture

## Architecture Overview

In this model:
- **Shared Containers Account (Hub)**: Centralized services that all customers use
- **Customer Accounts (Spokes)**: Each customer runs their own EKS cluster
- **Connections**: Customers connect to hub for shared services

```
┌──────────────────────────────────────────────────────────┐
│           Shared Containers Account (Hub)                │
│                                                           │
│  ┌────────────────────────────────────────────────┐     │
│  │         Shared Services EKS Cluster            │     │
│  │                                                 │     │
│  │  • ECR Container Registry                      │     │
│  │  • CI/CD Pipeline (ArgoCD, Tekton)            │     │
│  │  • Centralized Logging (OpenSearch/CloudWatch)│     │
│  │  • Centralized Monitoring (Prometheus/Grafana)│     │
│  │  • Service Mesh Control Plane (Istio)         │     │
│  │  • Secrets Management (Vault)                  │     │
│  │  • API Gateway                                 │     │
│  └────────────────────────────────────────────────┘     │
│                                                           │
│  Network Load Balancers (PrivateLink endpoints)         │
│  CloudWatch Log Groups                                   │
│  S3 Buckets (artifacts, backups)                        │
└──────────────┬──────────────┬──────────────┬────────────┘
               │              │              │
     ┌─────────┘              │              └──────────┐
     │                        │                         │
┌────▼──────────┐    ┌────────▼────────┐    ┌─────────▼──────┐
│  Customer1    │    │   Customer2     │    │   Customer3    │
│  Account      │    │   Account       │    │   Account      │
│               │    │                 │    │                │
│ ┌───────────┐ │    │ ┌─────────────┐│    │ ┌────────────┐ │
│ │EKS Cluster│ │    │ │ EKS Cluster ││    │ │EKS Cluster │ │
│ │           │ │    │ │             ││    │ │            │ │
│ │• Workloads│ │    │ │ • Workloads ││    │ │• Workloads │ │
│ │• Data     │ │    │ │ • Data      ││    │ │• Data      │ │
│ │• Agents   │ │    │ │ • Agents    ││    │ │• Agents    │ │
│ └───────────┘ │    │ └─────────────┘│    │ └────────────┘ │
│               │    │                 │    │                │
│ VPC Endpoints │    │  VPC Endpoints  │    │ VPC Endpoints  │
│ IAM Roles     │    │  IAM Roles      │    │ IAM Roles      │
└───────────────┘    └─────────────────┘    └────────────────┘
```

## Why This Model?

### Advantages vs Single Multi-Tenant Cluster:

✅ **Strong Isolation**
- Complete network isolation (separate VPCs)
- Separate control planes per customer
- No "noisy neighbor" at Kubernetes level
- Blast radius limited to single customer

✅ **Compliance & Governance**
- Meets strict regulatory requirements
- Clear account boundaries for auditing
- Customer data stays in customer account
- Easier to implement data residency rules

✅ **Customer Control**
- Customers can manage their own cluster upgrades
- Different Kubernetes versions per customer
- Customer-specific configurations
- Full admin access within their cluster

✅ **Resource Sharing Where It Matters**
- Shared container images (ECR)
- Shared CI/CD pipelines
- Shared observability platform
- Shared operational expertise

### Disadvantages:

❌ **Higher Overhead**
- More EKS control planes ($73/month each)
- More operational complexity
- More NAT gateways (if not using PrivateLink)

❌ **Network Complexity**
- VPC peering or Transit Gateway required
- Cross-account networking setup
- More firewall rules to manage

## Connection Patterns

### 1. ECR Container Registry Sharing (Most Common)

**Setup:**

1. **In Shared Containers Account** - Create ECR repository with cross-account policy:

```bash
# Create repository
aws ecr create-repository \
  --repository-name shared/platform-app \
  --region us-east-1 \
  --profile shared-containers

# Set repository policy
cat > ecr-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowCustomerPull",
      "Effect": "Allow",
      "Principal": {
        "AWS": [
          "arn:aws:iam::111111111111:root",
          "arn:aws:iam::222222222222:root",
          "arn:aws:iam::333333333333:root"
        ]
      },
      "Action": [
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:BatchCheckLayerAvailability",
        "ecr:DescribeImages",
        "ecr:DescribeRepositories",
        "ecr:ListImages"
      ]
    }
  ]
}
EOF

aws ecr set-repository-policy \
  --repository-name shared/platform-app \
  --policy-text file://ecr-policy.json \
  --region us-east-1 \
  --profile shared-containers
```

2. **In Customer Account** - Create IAM role for nodes to pull images:

```yaml
# IAM Policy for customer nodes
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage"
      ],
      "Resource": "arn:aws:ecr:us-east-1:SHARED-ACCOUNT-ID:repository/shared/*"
    }
  ]
}
```

3. **Customer Deployment** uses shared image:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: platform-app
spec:
  template:
    spec:
      containers:
      - name: app
        image: 123456789012.dkr.ecr.us-east-1.amazonaws.com/shared/platform-app:v1.0
        imagePullPolicy: Always
```

**No imagePullSecrets needed** - node IAM role handles authentication!

---

### 2. Centralized Logging

**Option A: CloudWatch Logs (Simplest)**

1. **In Shared Account** - Create log group and cross-account role:

```bash
# Create log group
aws logs create-log-group \
  --log-group-name /aws/eks/all-customers \
  --region us-east-1 \
  --profile shared-containers

# Create IAM role customers can assume
cat > trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": [
          "arn:aws:iam::111111111111:root",
          "arn:aws:iam::222222222222:root"
        ]
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "customer-logging"
        }
      }
    }
  ]
}
EOF

aws iam create-role \
  --role-name CrossAccountLoggingRole \
  --assume-role-policy-document file://trust-policy.json \
  --profile shared-containers

# Attach policy for writing logs
cat > logging-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams"
      ],
      "Resource": "arn:aws:logs:*:*:log-group:/aws/eks/all-customers:*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name CrossAccountLoggingRole \
  --policy-name LoggingPolicy \
  --policy-document file://logging-policy.json \
  --profile shared-containers
```

2. **In Customer Cluster** - Deploy FluentBit:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: fluent-bit
  namespace: kube-system
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::CUSTOMER-ACCOUNT:role/FluentBitRole
---
# Customer account IAM role that assumes shared account role
# (In customer account IAM)
# FluentBitRole → AssumeRole → CrossAccountLoggingRole (shared account)
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluent-bit-config
  namespace: kube-system
data:
  fluent-bit.conf: |
    [SERVICE]
        Flush         5
        Log_Level     info

    [INPUT]
        Name              tail
        Path              /var/log/containers/*.log
        Parser            docker
        Tag               kube.*
        Refresh_Interval  5

    [OUTPUT]
        Name cloudwatch_logs
        Match *
        region us-east-1
        log_group_name /aws/eks/all-customers
        log_stream_prefix customer1-${HOSTNAME}-
        auto_create_group false
        role_arn arn:aws:iam::SHARED-ACCOUNT:role/CrossAccountLoggingRole
        external_id customer-logging
```

**Option B: OpenSearch (Better for querying)**

```yaml
# FluentBit output to shared OpenSearch
[OUTPUT]
    Name opensearch
    Match *
    Host vpc-shared-opensearch-abc123.us-east-1.es.amazonaws.com
    Port 443
    TLS On
    AWS_Auth On
    AWS_Region us-east-1
    AWS_Role_ARN arn:aws:iam::SHARED-ACCOUNT:role/OpenSearchWriteRole
    Logstash_Format On
    Logstash_Prefix customer1
    Type _doc
```

---

### 3. Centralized Monitoring (Prometheus/Grafana)

**Using Amazon Managed Prometheus (AMP):**

1. **In Shared Account** - Create AMP workspace:

```bash
aws amp create-workspace \
  --alias shared-prometheus \
  --region us-east-1 \
  --profile shared-containers
```

2. **In Customer Cluster** - Configure Prometheus remote write:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
data:
  prometheus.yml: |
    global:
      scrape_interval: 30s
      external_labels:
        cluster: customer1-prod
        account: customer1

    remote_write:
      - url: https://aps-workspaces.us-east-1.amazonaws.com/workspaces/ws-abc123/api/v1/remote_write
        sigv4:
          region: us-east-1
        queue_config:
          max_samples_per_send: 1000
          max_shards: 200
          capacity: 2500

    scrape_configs:
      - job_name: 'kubernetes-pods'
        kubernetes_sd_configs:
          - role: pod
```

3. **In Shared Account** - Grafana queries AMP:

```yaml
# Grafana datasource config
apiVersion: 1
datasources:
  - name: AMP-All-Clusters
    type: prometheus
    url: https://aps-workspaces.us-east-1.amazonaws.com/workspaces/ws-abc123
    jsonData:
      httpMethod: POST
      sigV4Auth: true
      sigV4Region: us-east-1
```

**Query across all clusters:**
```promql
# CPU usage by cluster
sum by (cluster) (rate(container_cpu_usage_seconds_total[5m]))

# Filter to specific customer
sum by (pod) (rate(container_cpu_usage_seconds_total{cluster="customer1-prod"}[5m]))
```

---

### 4. Network Connectivity (PrivateLink - Recommended)

**For shared services that need network access (databases, APIs, etc.)**

1. **In Shared Account** - Create NLB + VPC Endpoint Service:

```bash
# Create NLB pointing to shared service
aws elbv2 create-load-balancer \
  --name shared-api-nlb \
  --type network \
  --scheme internal \
  --subnets subnet-abc123 subnet-def456 \
  --profile shared-containers

# Create VPC Endpoint Service
aws ec2 create-vpc-endpoint-service-configuration \
  --network-load-balancer-arns arn:aws:elasticloadbalancing:...:loadbalancer/net/shared-api-nlb/... \
  --acceptance-required \
  --profile shared-containers

# Note the service name: com.amazonaws.vpce.us-east-1.vpce-svc-abc123
```

2. **In Customer Account** - Create VPC Endpoint:

```bash
# Create endpoint in customer VPC
aws ec2 create-vpc-endpoint \
  --vpc-id vpc-customer1 \
  --service-name com.amazonaws.vpce.us-east-1.vpce-svc-abc123 \
  --vpc-endpoint-type Interface \
  --subnet-ids subnet-customer1-a subnet-customer1-b \
  --security-group-ids sg-customer1-endpoint \
  --profile customer1
```

3. **In Shared Account** - Accept endpoint connection:

```bash
aws ec2 accept-vpc-endpoint-connections \
  --service-id vpce-svc-abc123 \
  --vpc-endpoint-ids vpce-xyz789 \
  --profile shared-containers
```

4. **In Customer Cluster** - Use ExternalName service:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: shared-api
spec:
  type: ExternalName
  externalName: vpce-xyz789-abc123.vpce-svc-abc123.us-east-1.vpce.amazonaws.com
  ports:
  - port: 443
    protocol: TCP
```

**Applications access it:**
```yaml
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      containers:
      - name: app
        env:
        - name: API_URL
          value: https://shared-api.default.svc.cluster.local
```

---

### 5. Service Mesh Federation (Istio Multi-Primary)

**Each cluster runs Istio, federated for cross-cluster service discovery:**

1. **In Shared Cluster** - Install Istio:

```bash
istioctl install -f - <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  values:
    global:
      meshID: shared-mesh
      multiCluster:
        clusterName: shared-cluster
      network: shared-network
EOF
```

2. **In Customer Cluster** - Install Istio with mesh federation:

```bash
istioctl install -f - <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  values:
    global:
      meshID: shared-mesh
      multiCluster:
        clusterName: customer1-cluster
      network: customer1-network
EOF
```

3. **Enable Cross-Cluster Communication:**

```bash
# From shared cluster, create secret for customer1
istioctl x create-remote-secret \
  --context=shared-cluster \
  --name=customer1-cluster | \
  kubectl apply -f - --context=customer1-cluster

# From customer1, create secret for shared
istioctl x create-remote-secret \
  --context=customer1-cluster \
  --name=shared-cluster | \
  kubectl apply -f - --context=shared-cluster
```

4. **Deploy service in shared cluster:**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: auth-service
  namespace: shared-services
spec:
  ports:
  - port: 8080
  selector:
    app: auth
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: auth
  namespace: shared-services
spec:
  template:
    metadata:
      labels:
        app: auth
    spec:
      containers:
      - name: auth
        image: auth-service:v1
        ports:
        - containerPort: 8080
```

5. **Access from customer cluster:**

```yaml
# Automatically discovers service via Istio
apiVersion: apps/v1
kind: Deployment
metadata:
  name: customer-app
spec:
  template:
    spec:
      containers:
      - name: app
        env:
        - name: AUTH_URL
          value: http://auth-service.shared-services.svc.cluster.local:8080
```

Istio handles routing across clusters transparently!

---

## Complete Setup Guide

### Step 1: Set Up Shared Containers Account

```bash
# 1. Deploy shared services cluster
eksctl create cluster \
  --name shared-services \
  --region us-east-1 \
  --version 1.32 \
  --nodegroup-name platform \
  --node-type m5.xlarge \
  --nodes 3 \
  --profile shared-containers

# 2. Install platform services
kubectl apply -f shared-services/
  # - ArgoCD
  # - Prometheus
  # - Grafana
  # - OpenSearch
  # - Istio control plane

# 3. Create ECR repositories
aws ecr create-repository --repository-name shared/base-images
aws ecr create-repository --repository-name shared/platform-services

# 4. Set up cross-account IAM roles
# See detailed policies above
```

### Step 2: Onboard Customer Account

```bash
# 1. Customer creates their EKS cluster
eksctl create cluster \
  --name customer1-prod \
  --region us-east-1 \
  --version 1.32 \
  --profile customer1

# 2. Configure ECR access
# Add customer account to ECR policies in shared account

# 3. Deploy logging agent
kubectl apply -f fluent-bit-cloudwatch.yaml

# 4. Deploy monitoring agent
kubectl apply -f prometheus-remote-write.yaml

# 5. Create PrivateLink endpoints (if needed)
# For accessing shared services

# 6. Test connectivity
kubectl run test --image=shared-account.dkr.ecr.us-east-1.amazonaws.com/shared/test:v1
```

---

## Cost Comparison

### Single Multi-Tenant Cluster
- 1x EKS Control Plane: $73/month
- Shared node pool: $400/month
- **Total: ~$473/month** for all customers

### Hub-and-Spoke (3 customers)
- 1x Shared cluster: $73/month
- 3x Customer clusters: 3 × $73 = $219/month
- Customer nodes: 3 × $300 = $900/month
- Shared services nodes: $400/month
- Transit Gateway (optional): $36/month + data transfer
- **Total: ~$1,628/month**

**Cost is ~3.5x higher but provides:**
- Complete isolation
- Customer control
- Compliance/regulatory benefits
- Better for large customers

---

## When to Use Each Model

### Use Single Multi-Tenant Cluster When:
- All workloads are internal teams
- Moderate security requirements
- Cost optimization is priority
- Centralized operations preferred
- < 10 tenants

### Use Hub-and-Spoke When:
- External customers with their own AWS accounts
- Strict isolation requirements (compliance, security)
- Customers need cluster admin access
- Different SLAs per customer
- Large scale (10+ customers)
- Regulatory requirements mandate separate accounts

---

## Migration Path

If you need to transition from current single-cluster to hub-spoke:

### Phase 1: Set Up Hub
1. Deploy shared services cluster
2. Move CI/CD to hub
3. Set up centralized logging/monitoring
4. Create ECR repositories with cross-account access

### Phase 2: Onboard First Customer
1. Create customer EKS cluster
2. Connect to shared ECR
3. Connect to shared logging/monitoring
4. Migrate one workload as proof-of-concept

### Phase 3: Scale
1. Document onboarding process
2. Create Terraform modules
3. Automate customer cluster creation
4. Self-service onboarding portal

### Phase 4: Decommission Old Cluster
1. Migrate all workloads
2. Validate in new architecture
3. Shut down multi-tenant cluster
