# Quick Start: Deploy Flask App with EBS Persistent Storage

This guide will deploy a Flask application with EBS-backed persistent storage and verify it works.

## Prerequisites

- AWS CLI configured with profile `WorkloadConfig`
- Docker installed
- kubectl installed
- jq installed (for JSON parsing in tests)

## One-Command Deployment

Deploy everything and run tests:

```bash
./scripts/deploy-and-test-ebs.sh
```

This script will:
1. ✅ Deploy EKS cluster with EBS CSI driver (~15-20 minutes)
2. ✅ Build and push Flask app Docker image (~2 minutes)
3. ✅ Deploy StatefulSet with 2 replicas and EBS volumes (~2 minutes)
4. ✅ Run automated tests to verify persistent storage works
5. ✅ Display EBS volume IDs and verification

**Expected output:**
```
[HH:MM:SS] ✓ EKS cluster deployed
[HH:MM:SS] ✓ EBS CSI driver ready
[HH:MM:SS] ✓ Image pushed to ECR
[HH:MM:SS] ✓ Flask app deployed
[HH:MM:SS] ✓ PVCs created successfully
[HH:MM:SS] ✓ Health check passed
[HH:MM:SS] ✓ Entries created
[HH:MM:SS] ✓ Entries retrieved: 2 total
[HH:MM:SS] ✓ Storage verified on pods
[HH:MM:SS] ✓ EBS volumes mapped

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 ✓ EKS cluster deployed with EBS CSI driver
 ✓ Flask app with persistent storage deployed
 ✓ 2 entries successfully stored on EBS volumes
 ✓ Persistent storage verified working
```

## Test Persistence

After deployment, test that data persists across pod restarts:

```bash
./scripts/test-persistence.sh
```

**What it does:**
1. Adds test entries to storage
2. Records how many entries exist
3. **Deletes a pod** (simulates failure)
4. Waits for Kubernetes to recreate the pod
5. Verifies all data is still there

**Expected output:**
```
[HH:MM:SS] ✓ Test data added (4 entries)
[HH:MM:SS] Deleting pod flask-app-0 to test persistence...
[HH:MM:SS] ✓ Pod recreated
[HH:MM:SS] ✓ SUCCESS: Data persisted! (4 entries found)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Persistence Test Results:
   Before pod deletion: 4 entries
   After pod deletion:  4 entries

   ✓ EBS volume successfully retained data across pod restart
   ✓ StatefulSet correctly reattached the same PVC to the new pod
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Manual Testing

### Access the Application

```bash
# Port-forward to the service
kubectl port-forward -n tenant-customer1 svc/flask-app 8080:80
```

In another terminal:

```bash
# Check health
curl http://localhost:8080/health

# Add an entry
curl -X POST http://localhost:8080/entries \
  -H "Content-Type: application/json" \
  -d '{"message": "Hello from EBS!"}'

# List all entries
curl http://localhost:8080/entries | jq .

# Get app info
curl http://localhost:8080/ | jq .
```

### Verify EBS Volumes

```bash
# List PVCs (one per StatefulSet replica)
kubectl get pvc -n tenant-customer1

# List PVs with storage class
kubectl get pv

# Get EBS volume IDs
kubectl get pv -o json | jq -r '.items[] | 
  select(.spec.storageClassName=="ebs-gp3") | 
  "\(.metadata.name) -> \(.spec.csi.volumeHandle)"'

# Check EBS volumes in AWS Console or CLI
aws ec2 describe-volumes \
  --region ap-southeast-2 \
  --profile WorkloadConfig \
  --filters "Name=tag:kubernetes.io/created-for/pvc/name,Values=data-flask-app-*" \
  --query 'Volumes[*].[VolumeId,Size,State,VolumeType,Encrypted]' \
  --output table
```

## What Was Changed

### 1. Application Code (`app/app.py`)
- Added persistent file storage at `/data/entries.json`
- New API endpoints for CRUD operations
- Health check verifies storage is writable
- Tracks which pod handled each request

### 2. Kubernetes Manifests (`modules/flask-app.yaml`)
- **Deployment → StatefulSet**: For stable pod identity and storage
- **Added StorageClass**: `ebs-gp3` with encryption
- **Added volumeClaimTemplate**: Auto-creates 5Gi PVC per replica
- **Added volumeMount**: Mounts `/data` in each pod

### 3. RBAC (`modules/rbac.yaml`)
- Added read access to StorageClasses
- Already had full PVC management permissions

## Architecture

```
┌─────────────────────────────────────────┐
│  Service: flask-app (ClusterIP)         │
│           Load balances across pods     │
└─────────────┬───────────────────────────┘
              │
    ┌─────────┴─────────┐
    │                   │
    ▼                   ▼
┌─────────┐         ┌─────────┐
│ Pod 0   │         │ Pod 1   │
│ /data ──┼─────┐   │ /data ──┼─────┐
└─────────┘     │   └─────────┘     │
                │                   │
                ▼                   ▼
         ┌───────────┐       ┌───────────┐
         │ PVC 0     │       │ PVC 1     │
         │ 5Gi gp3   │       │ 5Gi gp3   │
         └─────┬─────┘       └─────┬─────┘
               │                   │
               ▼                   ▼
        ┌──────────┐        ┌──────────┐
        │ EBS Vol  │        │ EBS Vol  │
        │ Encrypted│        │ Encrypted│
        └──────────┘        └──────────┘
```

**Key Points:**
- Each pod has its own independent EBS volume
- Data on Pod 0 ≠ Data on Pod 1
- Volumes persist across pod restarts
- StatefulSet ensures same pod → same volume

## Cleanup

```bash
# Delete application (keeps PVCs)
kubectl delete -f modules/flask-app.yaml

# Delete PVCs (this deletes EBS volumes too)
kubectl delete pvc -n tenant-customer1 -l app=flask-app

# Delete entire cluster
aws cloudformation delete-stack \
  --stack-name eks-identity \
  --region ap-southeast-2 \
  --profile WorkloadConfig
```

## Troubleshooting

### PVC stuck in Pending

```bash
kubectl describe pvc -n tenant-customer1 data-flask-app-0
```

Check:
- EBS CSI driver pods running: `kubectl get pods -n kube-system | grep ebs`
- Node has capacity in the same AZ as the volume

### App can't write to /data

```bash
kubectl exec -n tenant-customer1 flask-app-0 -- ls -ld /data
kubectl logs -n tenant-customer1 flask-app-0
```

Verify volume is mounted and has correct permissions.

### Data not persisting

```bash
# Check if PV is actually bound
kubectl get pv

# Verify reclaim policy
kubectl get pv -o custom-columns=NAME:.metadata.name,RECLAIM:.spec.persistentVolumeReclaimPolicy

# Check if StatefulSet is managing the right PVCs
kubectl get statefulset -n tenant-customer1 flask-app -o yaml | grep -A 10 volumeClaimTemplates
```

## Next Steps

- Scale the StatefulSet: `kubectl scale statefulset/flask-app -n tenant-customer1 --replicas=3`
- Monitor storage usage: `kubectl exec -n tenant-customer1 flask-app-0 -- df -h /data`
- Configure backups: Set up EBS snapshots via AWS Backup
- Expand volume size: Edit PVC (requires `allowVolumeExpansion: true`)

## Documentation

- Full documentation: [EBS-STORAGE.md](./EBS-STORAGE.md)
- Deployment script: [scripts/deploy-and-test-ebs.sh](./scripts/deploy-and-test-ebs.sh)
- Persistence test: [scripts/test-persistence.sh](./scripts/test-persistence.sh)
