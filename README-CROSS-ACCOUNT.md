# Cross-Account EKS Deployment

## 🎯 What This Does

Deploys a **single EKS cluster** with the control plane in a hub account and worker nodes in a separate spoke account.

- **Hub Account**: EKS control plane only
- **Spoke Account**: EC2 worker nodes only
- Nodes authenticate via IAM across accounts and join the hub cluster

## 🚀 Quick Start

```bash
# 1. Configure AWS profiles
./setup-aws-profiles.sh

# 2. Gather VPC information
./gather-vpc-info.sh

# 3. Deploy everything (20-25 minutes)
./deploy-cross-account-eks.sh

# 4. Verify deployment
kubectl get nodes
kubectl apply -f test-deployment.yaml
```

## 📁 Key Files

### Deployment Scripts
- `setup-aws-profiles.sh` - Configure AWS CLI profiles for hub and spoke
- `gather-vpc-info.sh` - Collect VPC and subnet IDs
- `deploy-cross-account-eks.sh` - Main deployment script (deploys everything)

### CloudFormation Templates
- `cfn/hub-cluster-with-cross-account-nodes.yaml` - Hub cluster (control plane only)
- `cfn/spoke-nodegroup-only.yaml` - Spoke nodegroup (nodes only)

### Documentation
- `DEPLOYMENT-INSTRUCTIONS.md` - Complete step-by-step guide
- `CROSS-ACCOUNT-NODEGROUPS.md` - Architecture deep-dive
- `QUICK-REFERENCE.md` - Common commands reference

### Testing
- `test-deployment.yaml` - Sample nginx deployment for verification

## 📊 Architecture

```
Hub Account (Control Plane)
    ↓ IAM Authentication
Spoke Account (Worker Nodes)
```

**Key Innovation:** Uses EKS Access Entries API to map cross-account IAM roles to Kubernetes identities.

## 💰 Cost Savings

| Setup | Cost/month |
|-------|------------|
| 2 separate clusters | $468 |
| Cross-account nodes | $395 |
| **Savings** | **$73** |

## ✅ What Gets Deployed

### Hub Account
- EKS cluster `hub-shared-cluster`
- Control plane with all add-ons
- IAM role for cluster
- Security group for cluster

### Spoke Account
- Auto Scaling Group with 3 Bottlerocket nodes
- IAM role for nodes (with cross-account permissions)
- Security group for nodes
- Launch template with cluster connection details

### Cross-Account Configuration
- EKS Access Entry (hub → spoke node role)
- Policy association (AmazonEKSWorkerNodePolicy)

## 🔧 Prerequisites

- [ ] Two AWS accounts
- [ ] AWS CLI installed
- [ ] kubectl installed
- [ ] VPCs with subnets in both accounts
- [ ] Credentials for both accounts

## 📖 Documentation Structure

1. **Start Here**: `DEPLOYMENT-INSTRUCTIONS.md`
   - Prerequisites
   - Step-by-step deployment
   - Verification
   - Troubleshooting

2. **Deep Dive**: `CROSS-ACCOUNT-NODEGROUPS.md`
   - How authentication works
   - Network architecture
   - Security considerations
   - Cost analysis

3. **Daily Use**: `QUICK-REFERENCE.md`
   - Common kubectl commands
   - AWS CLI operations
   - Troubleshooting commands

## 🎓 How It Works

1. **Node Bootstrap**: Spoke nodes launch with IAM role credentials
2. **Authentication**: Nodes create AWS SigV4 signed tokens
3. **Validation**: Hub cluster validates tokens via AWS IAM
4. **Authorization**: Access Entry maps IAM role → Kubernetes identity
5. **Join**: Nodes successfully join cluster and receive workloads

**The Magic**: EKS Access Entries allow cross-account IAM principals to authenticate!

## 🔐 Security Features

- ✅ Strong account isolation
- ✅ IAM-based authentication
- ✅ Node labels for workload placement
- ✅ Security groups control network access
- ✅ Audit logging enabled
- ✅ Encrypted EBS volumes

## 🛠️ Common Operations

### View Cluster Status
```bash
kubectl get nodes
kubectl get pods -A
```

### Scale Nodes
```bash
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name customer1-nodes-asg \
  --desired-capacity 5 \
  --profile spoke1
```

### Add Another Spoke Account
See "Adding More Spoke Accounts" section in `DEPLOYMENT-INSTRUCTIONS.md`

### Cleanup
```bash
# Delete spoke first
aws cloudformation delete-stack --stack-name spoke-customer1-nodes --profile spoke1

# Then delete hub
aws cloudformation delete-stack --stack-name hub-eks-cluster --profile hub
```

## 🐛 Troubleshooting

### Nodes Not Joining?
1. Check access entry: `aws eks list-access-entries --cluster-name hub-shared-cluster --profile hub`
2. Verify NAT Gateway in spoke VPC
3. Check node logs: `journalctl -u kubelet -f`

### Pods Not Scheduling?
1. Check node labels: `kubectl get nodes --show-labels`
2. Verify node selector in pod spec
3. Check node resources: `kubectl describe node <node-name>`

## 📚 Additional Resources

- [AWS EKS Best Practices](https://aws.github.io/aws-eks-best-practices/)
- [EKS Access Entries Documentation](https://docs.aws.amazon.com/eks/latest/userguide/access-entries.html)
- [Bottlerocket Documentation](https://bottlerocket.dev/)

## 🤝 Support

For issues:
1. Check CloudFormation stack events
2. Review EKS cluster logs in CloudWatch
3. Check node logs via SSM
4. See troubleshooting section in deployment guide

## 📝 Notes

- Region: **ap-southeast-2** (Sydney)
- Kubernetes version: **1.32**
- Node OS: **Bottlerocket**
- Instance type: **m5.large** (3 nodes)
- Authentication: **EKS Access Entries API**

## 🎯 Next Steps After Deployment

1. ✅ Deploy test workload
2. ⬜ Set up cross-account ECR
3. ⬜ Configure centralized logging
4. ⬜ Set up monitoring (Prometheus/Grafana)
5. ⬜ Implement RBAC per customer
6. ⬜ Configure cluster autoscaler
7. ⬜ Set up GitOps with ArgoCD

## 📞 Getting Help

- Review deployment logs: `aws cloudformation describe-stack-events --stack-name <stack-name>`
- Check kubectl context: `kubectl config current-context`
- Verify AWS profiles: `aws sts get-caller-identity --profile <profile>`
- Node debugging: `aws ssm start-session --target <instance-id>`

---

**Ready to deploy? Start with `./setup-aws-profiles.sh`**
