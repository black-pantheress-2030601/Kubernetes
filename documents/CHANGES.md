# Changes: EBS Persistent Storage Implementation

## Summary

Modified the Flask application to use EBS-backed persistent storage, demonstrating full lifecycle management of persistent volumes in a multi-tenant EKS cluster.

## Files Modified

### 1. `app/app.py`
**Before:** Simple Flask app with health check and hello endpoint  
**After:** Full CRUD API with persistent JSON storage

**Changes:**
- Added file-based storage at `/data/entries.json`
- New endpoints:
  - `GET /entries` - List all stored entries
  - `POST /entries` - Create new entry
  - `DELETE /entries/:id` - Delete entry
- Health check now verifies storage writability
- Each entry records timestamp and pod name

### 2. `modules/flask-app.yaml`
**Before:** Deployment with 2 replicas  
**After:** StatefulSet with volumeClaimTemplates

**Changes:**
- Added `StorageClass` for EBS GP3 volumes (encrypted)
- Changed `Deployment` to `StatefulSet` for stable pod identity
- Added `volumeClaimTemplates` to auto-create PVCs (5Gi per replica)
- Added `volumeMounts` to mount `/data` in each pod
- Added `HOSTNAME` environment variable for tracking

### 3. `modules/rbac.yaml`
**Change:** Added StorageClass read permissions for tenants

```yaml
- apiGroups: [storage.k8s.io]
  resources: [storageclasses]
  verbs: [get, list, watch]
```

This allows tenants to discover available storage classes when creating PVCs.

## Files Added

### 1. `scripts/deploy-and-test-ebs.sh`
Complete deployment and testing automation:
- Deploys EKS cluster with EBS CSI driver
- Builds and pushes Docker image to ECR
- Deploys StatefulSet with EBS volumes
- Runs comprehensive storage tests
- Verifies EBS volume IDs and mappings

### 2. `scripts/test-persistence.sh`
Persistence verification script:
- Adds test data to storage
- Deletes a pod (simulates failure)
- Verifies data persists after pod recreation
- Demonstrates StatefulSet behavior

### 3. `EBS-STORAGE.md`
Comprehensive documentation covering:
- Architecture diagrams
- Deployment procedures
- Testing instructions
- Troubleshooting guide
- Security features
- Cost considerations

### 4. `QUICKSTART-EBS.md`
Quick reference guide:
- One-command deployment
- Quick testing procedures
- Common operations
- Cleanup instructions

### 5. `CHANGES.md` (this file)
Summary of all modifications

## Testing

### Automated Test Suite

Run the full deployment and test:
```bash
./scripts/deploy-and-test-ebs.sh
```

Test persistence after deployment:
```bash
./scripts/test-persistence.sh
```

### What Gets Tested

1. ✅ EBS CSI driver installation
2. ✅ StorageClass creation
3. ✅ PVC automatic provisioning
4. ✅ EBS volume creation and attachment
5. ✅ Storage writability
6. ✅ Data persistence across pod restarts
7. ✅ StatefulSet PVC reattachment
8. ✅ Multi-replica independent volumes

## Key Features Demonstrated

### 1. Persistent Storage
- Data survives pod deletion and recreation
- Each StatefulSet replica has independent storage
- EBS volumes automatically provisioned via CSI driver

### 2. StatefulSet Behavior
- Stable pod naming: `flask-app-0`, `flask-app-1`
- Stable storage: pod always reattaches to same PVC
- Ordered deployment and termination
- Automatic PVC creation per replica

### 3. Multi-Tenancy
- RBAC allows tenants to create PVCs
- Tenants can discover available storage classes
- Namespace isolation maintained
- Tenants cannot modify cluster-level storage classes

### 4. Security
- EBS volumes encrypted at rest
- IAM roles for service accounts (IRSA)
- Namespace-scoped access
- Read-only access to StorageClasses

## Architecture

```
Tenant Namespace (tenant-customer1)
├── StatefulSet: flask-app
│   ├── Pod: flask-app-0
│   │   └── Volume Mount: /data
│   │       └── PVC: data-flask-app-0 (5Gi gp3)
│   │           └── EBS Volume: vol-xxxxx (encrypted)
│   └── Pod: flask-app-1
│       └── Volume Mount: /data
│           └── PVC: data-flask-app-1 (5Gi gp3)
│               └── EBS Volume: vol-yyyyy (encrypted)
├── Service: flask-app (ClusterIP)
└── StorageClass: ebs-gp3 (cluster-wide)
```

## Before/After Comparison

| Aspect | Before | After |
|--------|--------|-------|
| **Deployment Type** | Deployment | StatefulSet |
| **Storage** | None (ephemeral) | EBS-backed PVCs |
| **Data Persistence** | Lost on pod restart | Persists across restarts |
| **Pod Identity** | Random names | Stable ordinal names |
| **Storage Isolation** | N/A | Per-replica volumes |
| **API Capabilities** | Health + Hello | Full CRUD with persistence |
| **RBAC** | PVC management only | PVC + StorageClass read |

## Verification Steps

After deployment, verify:

```bash
# 1. Check PVCs created
kubectl get pvc -n tenant-customer1
# Expected: data-flask-app-0, data-flask-app-1 (Bound, 5Gi)

# 2. Check PVs provisioned
kubectl get pv
# Expected: 2 PVs with storageClassName: ebs-gp3

# 3. Check EBS volumes in AWS
aws ec2 describe-volumes \
  --region ap-southeast-2 \
  --filters "Name=tag:kubernetes.io/created-for/pvc/name,Values=data-flask-app-*"
# Expected: 2 EBS volumes, 5GB each, encrypted, type gp3

# 4. Check StatefulSet status
kubectl get statefulset -n tenant-customer1
# Expected: READY 2/2

# 5. Test API
kubectl port-forward -n tenant-customer1 svc/flask-app 8080:80
curl http://localhost:8080/health
# Expected: {"status":"ok","storage":true}

# 6. Add data
curl -X POST http://localhost:8080/entries \
  -H "Content-Type: application/json" \
  -d '{"message":"test"}'

# 7. Delete pod
kubectl delete pod -n tenant-customer1 flask-app-0

# 8. Wait for recreation
kubectl wait --for=condition=ready pod -n tenant-customer1 flask-app-0 --timeout=120s

# 9. Verify data persisted
curl http://localhost:8080/entries
# Expected: Entry from step 6 still present
```

## Cost Impact

- **Storage**: ~$0.08/GB-month for GP3
- **2 replicas × 5Gi**: ~$0.80/month
- **Baseline performance**: 3,000 IOPS, 125 MB/s included
- **No additional cost** for encryption

## Rollback

To revert to the original Deployment without storage:

```bash
# 1. Delete StatefulSet
kubectl delete statefulset -n tenant-customer1 flask-app

# 2. Revert app.py to original version
git checkout HEAD~1 -- app/app.py

# 3. Revert flask-app.yaml to original Deployment
git checkout HEAD~1 -- modules/flask-app.yaml

# 4. Apply original manifests
kubectl apply -f modules/flask-app.yaml
```

Note: PVCs and EBS volumes persist. Delete manually if needed:
```bash
kubectl delete pvc -n tenant-customer1 -l app=flask-app
```

## Next Steps

Potential enhancements:
1. Add snapshot/backup automation
2. Implement volume expansion on storage threshold
3. Add monitoring/alerting for storage metrics
4. Configure PVC retention policies
5. Add cross-AZ replication for HA
6. Implement storage quotas per tenant

## References

- EBS CSI Driver: https://github.com/kubernetes-sigs/aws-ebs-csi-driver
- StatefulSets: https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/
- Persistent Volumes: https://kubernetes.io/docs/concepts/storage/persistent-volumes/
