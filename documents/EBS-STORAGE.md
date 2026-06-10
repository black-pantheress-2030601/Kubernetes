# EBS Persistent Storage Testing

This document describes the EBS-backed persistent storage implementation for the Flask application.

## Overview

The Flask application has been modified to use EBS-backed persistent volumes for storing data. This demonstrates:

1. **Persistent storage** across pod restarts
2. **StatefulSet** deployment with volumeClaimTemplates
3. **EBS CSI driver** provisioning GP3 volumes
4. **RBAC permissions** for tenants to create PVCs

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  StatefulSet: flask-app (2 replicas)                    │
│  ┌────────────────┐          ┌────────────────┐         │
│  │ flask-app-0    │          │ flask-app-1    │         │
│  │                │          │                │         │
│  │ /data mount    │          │ /data mount    │         │
│  └────────┬───────┘          └────────┬───────┘         │
│           │                           │                 │
│           ▼                           ▼                 │
│  ┌────────────────┐          ┌────────────────┐         │
│  │ PVC: data-     │          │ PVC: data-     │         │
│  │ flask-app-0    │          │ flask-app-1    │         │
│  │ 5Gi gp3        │          │ 5Gi gp3        │         │
│  └────────┬───────┘          └────────┬───────┘         │
└───────────┼──────────────────────────┼──────────────────┘
            │                          │
            ▼                          ▼
   ┌─────────────────┐        ┌─────────────────┐
   │ EBS Volume      │        │ EBS Volume      │
   │ vol-xxxxx       │        │ vol-yyyyy       │
   │ 5Gi encrypted   │        │ 5Gi encrypted   │
   └─────────────────┘        └─────────────────┘
```

## Changes Made

### 1. Application Changes (`app/app.py`)

Added persistent storage capabilities:
- Stores entries in `/data/entries.json`
- Health endpoint checks storage writability
- API endpoints for CRUD operations on entries
- Each entry records which pod processed it

**New Endpoints:**
- `GET /` - Shows storage info and entry count
- `GET /entries` - List all stored entries
- `POST /entries` - Add new entry (requires JSON: `{"message": "text"}`)
- `DELETE /entries/:id` - Delete entry by ID

### 2. Kubernetes Manifests (`modules/flask-app.yaml`)

Changed from Deployment to StatefulSet:
- **StorageClass**: `ebs-gp3` with encryption enabled
- **StatefulSet**: Replaces Deployment for stable pod identity
- **VolumeClaimTemplate**: Auto-creates PVC per replica
- **Volume Mount**: `/data` mounted in each pod
- **PVC Specs**: 5Gi per pod, ReadWriteOnce, gp3 storage class

### 3. RBAC Updates (`modules/rbac.yaml`)

Added read-only access to StorageClasses:
- Tenants can list/get available storage classes
- Tenants can create/manage PVCs (already had this)
- Tenants cannot modify storage classes (cluster admin only)

## Deployment

### Full Deployment and Test

Deploy everything and run automated tests:

```bash
./scripts/deploy-and-test-ebs.sh
```

This script:
1. Deploys EKS cluster with EBS CSI driver
2. Builds and pushes Flask app Docker image to ECR
3. Deploys StatefulSet with EBS volumes
4. Runs comprehensive storage tests
5. Verifies EBS volume IDs are mapped

### Manual Deployment Steps

If you prefer manual steps:

1. **Deploy cluster** (if not already deployed):
   ```bash
   ./scripts/deploy.sh \
     --vpc-id vpc-0940d59dd70f7f67d \
     --subnet1 subnet-066506c4fa0e78004 \
     --subnet2 subnet-0d419041a14fc9eb5 \
     --subnet3 subnet-0f697a017d3f60635
   ```

2. **Build and push image**:
   ```bash
   cd app
   ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
   ECR_URI="${ACCOUNT_ID}.dkr.ecr.ap-southeast-2.amazonaws.com"
   
   docker build -t flask-app:latest .
   aws ecr get-login-password --region ap-southeast-2 | docker login --username AWS --password-stdin ${ECR_URI}
   docker tag flask-app:latest ${ECR_URI}/flask-app:latest
   docker push ${ECR_URI}/flask-app:latest
   ```

3. **Deploy application**:
   ```bash
   kubectl apply -f modules/flask-app.yaml
   kubectl rollout status statefulset/flask-app -n tenant-customer1
   ```

## Testing

### Test Persistence Across Pod Restarts

Run the automated persistence test:

```bash
./scripts/test-persistence.sh
```

This script:
1. Adds test entries to storage
2. Records entry count
3. Deletes a pod
4. Waits for pod to be recreated
5. Verifies all data is still present

### Manual Testing

1. **Port-forward to the service**:
   ```bash
   kubectl port-forward -n tenant-customer1 svc/flask-app 8080:80
   ```

2. **Check health**:
   ```bash
   curl http://localhost:8080/health
   # Should show: {"status":"ok","storage":true}
   ```

3. **Add entries**:
   ```bash
   curl -X POST http://localhost:8080/entries \
     -H "Content-Type: application/json" \
     -d '{"message": "Test entry 1"}'
   
   curl -X POST http://localhost:8080/entries \
     -H "Content-Type: application/json" \
     -d '{"message": "Test entry 2"}'
   ```

4. **List entries**:
   ```bash
   curl http://localhost:8080/entries | jq .
   ```

5. **Delete a pod**:
   ```bash
   kubectl delete pod -n tenant-customer1 flask-app-0
   ```

6. **Wait for pod to restart**:
   ```bash
   kubectl wait --for=condition=ready pod -n tenant-customer1 flask-app-0 --timeout=120s
   ```

7. **Verify data persisted**:
   ```bash
   curl http://localhost:8080/entries | jq .
   # Should still show all entries
   ```

### Verify EBS Volumes

Check PVCs and PVs:
```bash
# List PVCs
kubectl get pvc -n tenant-customer1

# List PVs with details
kubectl get pv

# Get EBS volume IDs
kubectl get pv -o json | jq -r '.items[] | select(.spec.storageClassName=="ebs-gp3") | "\(.metadata.name) -> \(.spec.csi.volumeHandle)"'
```

Check actual EBS volumes in AWS:
```bash
# List EBS volumes created by Kubernetes
aws ec2 describe-volumes \
  --region ap-southeast-2 \
  --filters "Name=tag:kubernetes.io/created-for/pvc/name,Values=data-flask-app-*" \
  --query 'Volumes[*].[VolumeId,Size,State,VolumeType,Encrypted]' \
  --output table
```

## Storage Behavior

### StatefulSet Guarantees

1. **Stable Identity**: Each pod gets a stable name (`flask-app-0`, `flask-app-1`)
2. **Stable Storage**: Each pod always reattaches to the same PVC
3. **Ordered Deployment**: Pods start in order (0, then 1)
4. **Ordered Termination**: Pods terminate in reverse order

### Data Isolation

Each replica has its own independent EBS volume:
- `flask-app-0` → `data-flask-app-0` PVC → EBS volume A
- `flask-app-1` → `data-flask-app-1` PVC → EBS volume B

Data written to one pod's storage is NOT visible to the other pod.

### Volume Lifecycle

1. **Creation**: PVC created when StatefulSet is deployed
2. **Binding**: EBS CSI driver provisions a GP3 volume
3. **Attachment**: Volume attaches to the node where pod runs
4. **Persistence**: Volume detaches if pod is deleted but is NOT deleted
5. **Reattachment**: When pod is recreated, same volume reattaches
6. **Manual Cleanup**: PVC and EBS volume persist until manually deleted

## Cleanup

To clean up resources:

```bash
# Delete the application (keeps PVCs)
kubectl delete statefulset -n tenant-customer1 flask-app

# Delete PVCs (this will delete the EBS volumes)
kubectl delete pvc -n tenant-customer1 -l app=flask-app

# Delete the entire cluster
aws cloudformation delete-stack \
  --stack-name eks-identity \
  --region ap-southeast-2 \
  --profile WorkloadConfig
```

## Cost Considerations

- **EBS GP3**: ~$0.08/GB-month
- **2 replicas × 5Gi**: ~$0.80/month for storage
- **GP3 baseline**: 3,000 IOPS and 125 MB/s included
- **Snapshots**: Additional cost if configured

## Security Features

1. **Encryption at rest**: All EBS volumes encrypted
2. **IAM roles**: EBS CSI driver uses IRSA (IAM Roles for Service Accounts)
3. **Network isolation**: Volumes only accessible within VPC
4. **Namespace isolation**: PVCs scoped to tenant namespace
5. **RBAC**: Tenants can only manage PVCs in their namespace

## Troubleshooting

### PVC stays in Pending state

Check events:
```bash
kubectl describe pvc -n tenant-customer1 data-flask-app-0
```

Common causes:
- EBS CSI driver not running
- No available nodes in the AZ
- IAM permissions missing

### Pod can't write to /data

Check volume mount:
```bash
kubectl describe pod -n tenant-customer1 flask-app-0
kubectl exec -n tenant-customer1 flask-app-0 -- ls -ld /data
```

### Storage not persisting

Verify PV reclaim policy:
```bash
kubectl get pv -o custom-columns=NAME:.metadata.name,RECLAIM:.spec.persistentVolumeReclaimPolicy
```

Should be `Retain` or `Delete` (StatefulSets default to `Delete`).

## References

- [EBS CSI Driver](https://github.com/kubernetes-sigs/aws-ebs-csi-driver)
- [StatefulSets](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/)
- [Persistent Volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)
- [Storage Classes](https://kubernetes.io/docs/concepts/storage/storage-classes/)
