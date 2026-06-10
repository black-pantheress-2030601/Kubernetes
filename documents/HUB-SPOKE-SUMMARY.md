# Hub-and-Spoke Architecture - Summary

## ✅ Files Created

### CloudFormation Templates (`cfn/`)
- **`hub-shared-services.yaml`** - Hub account infrastructure
- **`spoke-customer-cluster.yaml`** - Customer cluster template

### Deployment Scripts (`scripts/`)
- **`deploy-hub.sh`** - Deploy hub account
- **`deploy-spoke.sh`** - Deploy customer cluster

### Kubernetes Manifests (`manifests/`)
- **`fluentbit-hub.yaml`** - Centralized logging
- **`prometheus-hub.yaml`** - Centralized monitoring

### Documentation
- **`HUB-SPOKE-DEPLOYMENT-GUIDE.md`** - Complete guide
- **`HUB-SPOKE-ARCHITECTURE.md`** - Architecture details
- **`ARCHITECTURE-COMPARISON.md`** - Multi-tenant vs hub-spoke

## 🚀 Quick Start

### 1. Deploy Hub (Shared Services Account)
```bash
./scripts/deploy-hub.sh \
  --vpc-id vpc-xxx \
  --subnet1 subnet-xxx \
  --subnet2 subnet-yyy \
  --subnet3 subnet-zzz \
  --customer1-account 111111111111
```

**Creates:**
- ECR repositories (shared/images, shared/platform)
- CloudWatch log group (/aws/eks/all-customers)
- Amazon Managed Prometheus workspace
- Cross-account IAM roles

### 2. Push Images to Hub ECR
```bash
docker tag myapp:latest <hub>.dkr.ecr.region.amazonaws.com/shared/images:myapp
docker push <hub>.dkr.ecr.region.amazonaws.com/shared/images:myapp
```

### 3. Deploy Customer Cluster
```bash
./scripts/deploy-spoke.sh \
  --profile customer1 \
  --vpc-id vpc-xxx \
  --subnet1 subnet-xxx \
  --subnet2 subnet-yyy \
  --subnet3 subnet-zzz
```

**Creates:**
- Customer EKS cluster
- Nodes with ECR pull permissions
- Cross-account logging/monitoring roles

### 4. Deploy Application (in customer cluster)
```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
spec:
  template:
    spec:
      containers:
      - name: app
        image: <hub>.dkr.ecr.region.amazonaws.com/shared/images:myapp
EOF
```

**No imagePullSecrets needed!** Node IAM role handles authentication.

## 🔑 Key Concepts

### ECR Sharing
- Hub creates repositories with cross-account policies
- Customer nodes can pull without imagePullSecrets
- Single source of truth for container images

### Centralized Logging
- FluentBit in customer cluster → Hub CloudWatch
- All customers' logs in one place
- Query: `aws logs tail /aws/eks/all-customers`

### Centralized Monitoring
- Prometheus in customer cluster → Hub AMP
- All customers' metrics in one workspace
- Query across all clusters from Grafana in hub

## 📊 Architecture

```
┌────────────────────────────────┐
│  Hub Account                   │
│  • ECR (shared/images)         │
│  • CloudWatch Logs (all)       │
│  • Amazon Managed Prometheus   │
└──────┬────────────┬────────────┘
       │            │
   ┌───┴──┐     ┌───┴──┐
   │Cust1 │     │Cust2 │
   │ EKS  │     │ EKS  │
   └──────┘     └──────┘
```

## 🆚 vs Multi-Tenant

| Aspect | Multi-Tenant | Hub-Spoke |
|--------|--------------|-----------|
| **Clusters** | 1 shared | N+1 (hub + customers) |
| **Isolation** | Namespace | AWS Account |
| **Cost** | Lower | Higher |
| **Use Case** | Internal teams | External customers |
| **Compliance** | Moderate | Strong |

## 📖 Next Steps

1. Read **HUB-SPOKE-DEPLOYMENT-GUIDE.md** for detailed steps
2. Deploy hub account
3. Deploy first customer cluster
4. Test ECR pull, logging, and monitoring

## 💡 When to Use

**Use Hub-Spoke when:**
- ✅ Customers have their own AWS accounts
- ✅ Need strong isolation (compliance/regulatory)
- ✅ Customers need cluster admin access
- ✅ Different K8s versions per customer

**Use Multi-Tenant when:**
- ✅ All internal teams
- ✅ Same organization
- ✅ Cost optimization priority
- ✅ Simpler operations preferred
