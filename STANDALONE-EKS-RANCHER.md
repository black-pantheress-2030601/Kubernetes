# Standalone EKS Cluster with Rancher

## Prerequisites

- AWS CLI configured with appropriate permissions
- `kubectl` installed
- `helm` installed (`brew install helm`)

## 1. Deploy the EKS Cluster

The CloudFormation template (`cfn/standalone-eks-cluster.yaml`) creates:
- EKS cluster IAM role
- Node group IAM role (worker node policy, ECR read, VPC CNI)
- EKS cluster (K8s 1.32, public + private endpoints)
- Managed node group (2x t3.medium by default)

```bash
aws cloudformation create-stack \
  --stack-name standalone-eks-cluster \
  --template-body file://cfn/standalone-eks-cluster.yaml \
  --parameters \
    ParameterKey=ClusterName,ParameterValue=standalone-cluster \
    ParameterKey=VpcId,ParameterValue=vpc-0940d59dd70f7f67d \
    ParameterKey=Subnet1Id,ParameterValue=subnet-066506c4fa0e78004 \
    ParameterKey=Subnet2Id,ParameterValue=subnet-0f697a017d3f60635 \
    ParameterKey=Subnet3Id,ParameterValue=subnet-0d419041a14fc9eb5 \
  --capabilities CAPABILITY_NAMED_IAM \
  --region ap-southeast-2

# Wait for completion (~15 minutes)
aws cloudformation wait stack-create-complete \
  --stack-name standalone-eks-cluster --region ap-southeast-2
```

## 2. Configure kubectl

```bash
aws eks update-kubeconfig --name standalone-cluster --region us-east-1
kubectl get nodes
```

## 3. Install Rancher

### Add Helm repos

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
helm repo update
```

### Install cert-manager

```bash
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true
```

### Install Rancher

```bash
kubectl create namespace cattle-system

helm install rancher rancher-stable/rancher \
  --namespace cattle-system \
  --set hostname=rancher.local \
  --set bootstrapPassword=admin \
  --set replicas=1
```

### Expose via LoadBalancer

```bash
kubectl -n cattle-system expose deployment rancher \
  --type=LoadBalancer --name=rancher-lb --port=443 --target-port=443
```

### Get the ELB address

```bash
kubectl -n cattle-system get svc rancher-lb
```

### Add /etc/hosts entry

Rancher validates the Host header against its configured hostname. Point `rancher.local` at the ELB IP:

```bash
ELB_IP=$(dig +short $(kubectl -n cattle-system get svc rancher-lb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}') | head -1)
sudo sh -c "echo \"$ELB_IP  rancher.local\" >> /etc/hosts"
```

### Access Rancher

Open `https://rancher.local` in your browser. Accept the self-signed certificate warning.

- Bootstrap password: `admin`
- You'll be prompted to set a new password on first login.

## 4. Cleanup

### Revert /etc/hosts

```bash
sudo sed -i '' '/rancher.local/d' /etc/hosts
```

### Uninstall Rancher and cert-manager

```bash
helm uninstall rancher -n cattle-system
helm uninstall cert-manager -n cert-manager
kubectl delete namespace cattle-system
kubectl delete namespace cert-manager
```

### Delete the EKS cluster

```bash
aws cloudformation delete-stack --stack-name standalone-eks-cluster --region ap-southeast-2
aws cloudformation wait stack-delete-complete --stack-name standalone-eks-cluster --region ap-southeast-2
```
