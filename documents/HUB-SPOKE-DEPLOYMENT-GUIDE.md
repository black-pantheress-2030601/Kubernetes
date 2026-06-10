# Hub-and-Spoke Architecture Deployment Guide

## Overview

This guide walks you through deploying a hub-and-spoke multi-cluster architecture where:
- **Hub Account**: Provides shared services (ECR, logging, monitoring)
- **Spoke Accounts**: Customers run their own EKS clusters and connect to hub

```
┌─────────────────────────────────────┐
│      Hub Account (Shared)           │
│  • ECR Container Registry           │
│  • CloudWatch Logs (centralized)    │
│  • Amazon Managed Prometheus        │
│  • Optional: Shared services cluster│
└──────┬──────────┬───────────────────┘
       │          │
   ┌───┴──┐   ┌───┴──┐
   │Cust1 │   │Cust2 │
   │ EKS  │   │ EKS  │
   └──────┘   └──────┘
```

## Prerequisites

- AWS CLI configured with appropriate profiles
- kubectl installed
- Docker installed (for building/pushing images)
- At least 2 AWS accounts:
  - Hub account (shared services)
  - At least one customer account

## Files Created

### CloudFormation Templates
- **`cfn/hub-shared-services.yaml`** - Hub account infrastructure
- **`cfn/spoke-customer-cluster.yaml`** - Customer cluster template

### Deployment Scripts
- **`scripts/deploy-hub.sh`** - Deploy hub account
- **`scripts/deploy-spoke.sh`** - Deploy customer cluster

### Kubernetes Manifests
- **`manifests/fluentbit-hub.yaml`** - Send logs to hub CloudWatch
- **`manifests/prometheus-hub.yaml`** - Send metrics to hub Prometheus

## Deployment Steps

### Step 1: Deploy Hub Account

In your hub/shared services AWS account:

```bash
# Set up variables
HUB_PROFILE="WorkloadConfig"
HUB_REGION="ap-southeast-2"
CUSTOMER1_ACCOUNT="111111111111"  # Customer AWS Account ID
CUSTOMER2_ACCOUNT="222222222222"  # Optional

# Get VPC and subnet IDs
VPC_ID=$(aws ec2 describe-vpcs --profile ${HUB_PROFILE} --region ${HUB_REGION} \
  --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text)

SUBNETS=$(aws ec2 describe-subnets --profile ${HUB_PROFILE} --region ${HUB_REGION} \
  --filters "Name=vpc-id,Values=${VPC_ID}" --query 'Subnets[*].SubnetId' --output text)

SUBNET1=$(echo $SUBNETS | awk '{print $1}')
SUBNET2=$(echo $SUBNETS | awk '{print $2}')
SUBNET3=$(echo $SUBNETS | awk '{print $3}')

# Deploy hub
./scripts/deploy-hub.sh \
  --profile ${HUB_PROFILE} \
  --region ${HUB_REGION} \
  --vpc-id ${VPC_ID} \
  --subnet1 ${SUBNET1} \
  --subnet2 ${SUBNET2} \
  --subnet3 ${SUBNET3} \
  --customer1-account ${CUSTOMER1_ACCOUNT} \
  --customer2-account ${CUSTOMER2_ACCOUNT}
```

**What this creates:**
- ECR repositories: `shared/images`, `shared/platform`
- CloudWatch log group: `/aws/eks/all-customers`
- Amazon Managed Prometheus workspace
- Cross-account IAM roles for logging and monitoring
- Optional: Shared services EKS cluster

**Output:**
The script saves connection info to `.hub-connection-info` for use in spoke deployment.

---

### Step 2: Push Container Images to Hub ECR

```bash
# Login to ECR
HUB_ACCOUNT="123456789012"  # Your hub account ID
aws ecr get-login-password --region ${HUB_REGION} --profile ${HUB_PROFILE} \
  | docker login --username AWS --password-stdin ${HUB_ACCOUNT}.dkr.ecr.${HUB_REGION}.amazonaws.com

# Build and tag your application
cd app
docker build --platform linux/amd64 -t myapp:latest .
docker tag myapp:latest ${HUB_ACCOUNT}.dkr.ecr.${HUB_REGION}.amazonaws.com/shared/images:myapp-latest

# Push to hub ECR
docker push ${HUB_ACCOUNT}.dkr.ecr.${HUB_REGION}.amazonaws.com/shared/images:myapp-latest
```

---

### Step 3: Deploy Customer Cluster (Spoke)

In customer AWS account:

```bash
# Set up variables
CUSTOMER_PROFILE="customer1"
CUSTOMER_REGION="ap-southeast-2"
CUSTOMER_NAME="customer1"

# Get VPC and subnets in customer account
VPC_ID=$(aws ec2 describe-vpcs --profile ${CUSTOMER_PROFILE} --region ${CUSTOMER_REGION} \
  --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text)

SUBNETS=$(aws ec2 describe-subnets --profile ${CUSTOMER_PROFILE} --region ${CUSTOMER_REGION} \
  --filters "Name=vpc-id,Values=${VPC_ID}" --query 'Subnets[*].SubnetId' --output text)

SUBNET1=$(echo $SUBNETS | awk '{print $1}')
SUBNET2=$(echo $SUBNETS | awk '{print $2}')
SUBNET3=$(echo $SUBNETS | awk '{print $3}')

# Deploy spoke cluster
# Note: This automatically loads hub connection info from .hub-connection-info
./scripts/deploy-spoke.sh \
  --profile ${CUSTOMER_PROFILE} \
  --region ${CUSTOMER_REGION} \
  --customer-name ${CUSTOMER_NAME} \
  --vpc-id ${VPC_ID} \
  --subnet1 ${SUBNET1} \
  --subnet2 ${SUBNET2} \
  --subnet3 ${SUBNET3}
```

**What this creates:**
- Customer EKS cluster
- Node group with IAM permissions to pull from hub ECR
- IAM roles to assume hub logging/monitoring roles
- Pod Identity associations for FluentBit and Prometheus

---

### Step 4: Deploy Application Using Hub Images

In customer cluster:

```bash
# Make sure you're using customer cluster context
kubectl config current-context

# Deploy application
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: myapp
  template:
    metadata:
      labels:
        app: myapp
    spec:
      containers:
      - name: app
        image: ${HUB_ACCOUNT}.dkr.ecr.${HUB_REGION}.amazonaws.com/shared/images:myapp-latest
        ports:
        - containerPort: 5000
---
apiVersion: v1
kind: Service
metadata:
  name: myapp
spec:
  selector:
    app: myapp
  ports:
  - port: 80
    targetPort: 5000
  type: ClusterIP
EOF
```

**Verify it works:**
```bash
kubectl get pods
kubectl logs deployment/myapp
```

Images are automatically pulled from hub ECR - no imagePullSecrets needed!

---

### Step 5: Configure Centralized Logging

Deploy FluentBit in customer cluster:

```bash
# Load hub connection info
source .hub-connection-info

# Get cluster info
CLUSTER_NAME=$(kubectl config current-context | sed 's/.*\///')

# Update FluentBit manifest with actual values
cat manifests/fluentbit-hub.yaml | \
  sed "s/REPLACE_WITH_CLUSTER_NAME/${CLUSTER_NAME}/g" | \
  sed "s/REPLACE_WITH_CUSTOMER_NAME/${CUSTOMER_NAME}/g" | \
  sed "s|REPLACE_WITH_HUB_REGION|${HUB_REGION}|g" | \
  sed "s|REPLACE_WITH_HUB_LOGGING_ROLE|${HUB_LOG_ROLE}|g" | \
  kubectl apply -f -
```

**Verify logging:**
```bash
# Check FluentBit pods
kubectl get pods -n kube-system -l app=fluent-bit

# Check logs in hub account
aws logs tail /aws/eks/all-customers \
  --follow \
  --format short \
  --profile ${HUB_PROFILE} \
  --region ${HUB_REGION}
```

---

### Step 6: Configure Centralized Monitoring

Deploy Prometheus in customer cluster:

```bash
# Update Prometheus manifest with actual values
cat manifests/prometheus-hub.yaml | \
  sed "s/REPLACE_WITH_CLUSTER_NAME/${CLUSTER_NAME}/g" | \
  sed "s/REPLACE_WITH_CUSTOMER_NAME/${CUSTOMER_NAME}/g" | \
  sed "s|REPLACE_WITH_HUB_REGION|${HUB_REGION}|g" | \
  sed "s|REPLACE_WITH_HUB_PROMETHEUS_ROLE|${HUB_PROM_ROLE}|g" | \
  sed "s|REPLACE_WITH_HUB_PROMETHEUS_ENDPOINT|${HUB_PROM_ENDPOINT}|g" | \
  sed "s|REPLACE_WITH_REGION|${CUSTOMER_REGION}|g" | \
  kubectl apply -f -
```

**Verify monitoring:**
```bash
# Check Prometheus pod
kubectl get pods -n monitoring

# Port-forward to Prometheus UI
kubectl port-forward -n monitoring svc/prometheus 9090:9090

# Open browser to http://localhost:9090
# Query: up{cluster="customer1-prod"}
```

**In hub account**, query Amazon Managed Prometheus:
```bash
# Install awscurl or use Grafana
# Query all customer metrics
# Example: container_cpu_usage_seconds_total{cluster=~".*"}
```

---

## Verification Tests

### Test 1: ECR Pull from Customer Cluster

```bash
# In customer cluster
kubectl run test-ecr \
  --image=${HUB_ACCOUNT}.dkr.ecr.${HUB_REGION}.amazonaws.com/shared/images:myapp-latest \
  --restart=Never \
  -- sleep 3600

# Check if image pulled successfully
kubectl describe pod test-ecr | grep -A5 Events

# Should see: "Successfully pulled image"
# Clean up
kubectl delete pod test-ecr
```

### Test 2: Centralized Logging

```bash
# Generate test logs in customer cluster
kubectl run test-log --image=busybox --restart=Never -- sh -c "echo 'Test log from customer cluster'; sleep 60"

# Wait 30 seconds for FluentBit to ship logs

# Check in hub account
aws logs tail /aws/eks/all-customers \
  --filter-pattern "Test log" \
  --profile ${HUB_PROFILE} \
  --region ${HUB_REGION}

# Should see the test log
# Clean up
kubectl delete pod test-log
```

### Test 3: Centralized Monitoring

```bash
# In customer cluster, check Prometheus is scraping
kubectl exec -n monitoring deployment/prometheus -- \
  promtool check config /etc/prometheus/prometheus.yml

# Check remote write status
kubectl logs -n monitoring deployment/prometheus | grep "remote_write"

# Should see: "remote_write: Done replaying WAL"
```

### Test 4: Cross-Account Permissions

```bash
# Test that customer nodes can pull from hub ECR
# (This is tested implicitly when pods pull images)

# Test FluentBit can assume hub logging role
kubectl exec -n kube-system daemonset/fluent-bit -- \
  aws sts get-caller-identity

# Should show assumed role from hub account

# Test Prometheus can assume hub monitoring role
kubectl exec -n monitoring deployment/prometheus -- \
  env | grep AWS
```

---

## Multi-Customer Deployment

To add additional customers:

### In Hub Account:
1. Update hub stack with new customer account ID:
```bash
./scripts/deploy-hub.sh \
  --customer1-account 111111111111 \
  --customer2-account 222222222222 \
  --customer3-account 333333333333 \
  # ... other params
```

2. ECR and IAM roles automatically update to include new customer

### In New Customer Account:
1. Deploy spoke cluster using same process as Step 3
2. Deploy applications, FluentBit, and Prometheus

### Result:
- All customers pull from same ECR repositories
- All customers' logs appear in same CloudWatch log group (with customer prefix)
- All customers' metrics appear in same Prometheus workspace (with cluster label)

---

## Monitoring and Operations

### View All Customer Logs (Hub Account)

```bash
# Tail all customer logs
aws logs tail /aws/eks/all-customers --follow --profile ${HUB_PROFILE}

# Filter by customer
aws logs tail /aws/eks/all-customers \
  --filter-pattern "customer1" \
  --follow

# Query specific time range
aws logs tail /aws/eks/all-customers \
  --since 1h \
  --format short
```

### View All Customer Metrics (Hub Account)

Deploy Grafana in hub account to visualize all customer metrics:

```bash
# In hub shared services cluster
kubectl create namespace grafana

# Add Grafana Helm repo
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Install Grafana
helm install grafana grafana/grafana \
  --namespace grafana \
  --set service.type=LoadBalancer \
  --set persistence.enabled=true

# Get Grafana password
kubectl get secret --namespace grafana grafana -o jsonpath="{.data.admin-password}" | base64 --decode

# Get Grafana URL
kubectl get svc --namespace grafana grafana -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

**Add AMP data source in Grafana:**
1. Configuration → Data Sources → Add data source → Prometheus
2. URL: `https://aps-workspaces.${REGION}.amazonaws.com/workspaces/${WORKSPACE_ID}`
3. Auth: SigV4, Region: your region
4. Save & Test

**Create dashboard:**
- CPU by cluster: `sum by (cluster) (rate(container_cpu_usage_seconds_total[5m]))`
- Memory by cluster: `sum by (cluster) (container_memory_usage_bytes)`
- Pod count by customer: `count by (customer) (up{job="kubernetes-pods"})`

---

## Cost Breakdown

### Hub Account
- EKS control plane (optional): $73/month
- Amazon Managed Prometheus: $0.05/month + $0.10/million samples
- CloudWatch Logs: $0.50/GB ingested + $0.03/GB stored
- ECR storage: $0.10/GB/month
- S3 artifacts: $0.023/GB/month
- **Estimated: $100-300/month** (depends on volume)

### Each Customer Account
- EKS control plane: $73/month
- EC2 nodes: ~$140-300/month (depends on instance types)
- EBS volumes: ~$1-10/month
- Data transfer: ~$0-50/month
- **Estimated: $200-400/month per customer**

### Total for 3 Customers
- Hub: $200/month
- 3 Customers: 3 × $300 = $900/month
- **Total: ~$1,100/month**

**Shared savings:**
- No per-customer Prometheus/Grafana infrastructure ($50/customer saved)
- No per-customer log aggregation ($30/customer saved)
- Single container registry management
- **Saves ~$240/month compared to fully isolated per-customer infrastructure**

---

## Troubleshooting

### Issue: Customer cluster can't pull from hub ECR

**Check:**
```bash
# Verify node IAM role has ECR permissions
kubectl describe node | grep "iam.amazonaws.com/role"

# Test ECR login
aws ecr get-authorization-token --region ${HUB_REGION}

# Check ECR repository policy
aws ecr get-repository-policy \
  --repository-name shared/images \
  --region ${HUB_REGION} \
  --profile ${HUB_PROFILE}
```

**Fix:** Ensure customer account ID is in ECR repository policy

---

### Issue: FluentBit not sending logs to hub

**Check:**
```bash
# Check FluentBit pods
kubectl get pods -n kube-system -l app=fluent-bit

# Check FluentBit logs
kubectl logs -n kube-system daemonset/fluent-bit | tail -50

# Check Pod Identity association
kubectl describe sa fluent-bit -n kube-system

# Test assume role
kubectl exec -n kube-system daemonset/fluent-bit -- \
  aws sts assume-role \
    --role-arn ${HUB_LOG_ROLE} \
    --role-session-name test \
    --external-id centralized-logging
```

**Common causes:**
- Pod Identity not configured
- External ID mismatch
- Hub logging role trust policy missing customer account

---

### Issue: Prometheus not writing to AMP

**Check:**
```bash
# Check Prometheus logs
kubectl logs -n monitoring deployment/prometheus | grep -i error

# Check remote write config
kubectl exec -n monitoring deployment/prometheus -- \
  cat /etc/prometheus/prometheus.yml

# Test AMP endpoint
curl -v ${HUB_PROM_ENDPOINT}
```

**Common causes:**
- Incorrect endpoint URL
- Role ARN not configured
- SigV4 signing issues

---

## Security Considerations

### Least Privilege IAM Roles
- Hub ECR: Read-only access for customers
- Hub logging role: Write-only to specific log group
- Hub monitoring role: Write-only to specific AMP workspace
- No console access needed by customer applications

### Network Isolation
- Customer clusters in separate VPCs
- No direct network connectivity required
- All access via AWS API endpoints (ECR, CloudWatch, AMP)

### Audit Trail
- CloudTrail logs all cross-account AssumeRole calls
- CloudWatch Logs show which customer generated which logs
- Prometheus metrics tagged with cluster and customer labels

---

## Cleanup

### Delete Customer Cluster
```bash
aws cloudformation delete-stack \
  --stack-name customer1-cluster \
  --region ${CUSTOMER_REGION} \
  --profile ${CUSTOMER_PROFILE}
```

### Delete Hub Infrastructure
```bash
aws cloudformation delete-stack \
  --stack-name shared-services-hub \
  --region ${HUB_REGION} \
  --profile ${HUB_PROFILE}
```

**Note:** ECR repositories with images will fail to delete. Empty them first:
```bash
aws ecr batch-delete-image \
  --repository-name shared/images \
  --image-ids "$(aws ecr list-images --repository-name shared/images --query 'imageIds[*]' --output json)" \
  --region ${HUB_REGION} \
  --profile ${HUB_PROFILE}
```

---

## Next Steps

1. **Add More Customers**: Repeat spoke deployment for each customer
2. **Set Up Alerts**: Configure CloudWatch alarms or Grafana alerts
3. **Implement Network Connectivity**: If customers need shared services, set up PrivateLink
4. **Add Service Mesh**: Deploy Istio for cross-cluster service discovery
5. **Automate Onboarding**: Create Terraform modules for customer onboarding
6. **Set Up CI/CD**: Deploy ArgoCD in hub for GitOps-based deployments

## References

- Architecture comparison: [ARCHITECTURE-COMPARISON.md](./ARCHITECTURE-COMPARISON.md)
- Detailed hub-spoke concepts: [HUB-SPOKE-ARCHITECTURE.md](./HUB-SPOKE-ARCHITECTURE.md)
- CloudFormation templates: `cfn/hub-shared-services.yaml`, `cfn/spoke-customer-cluster.yaml`
