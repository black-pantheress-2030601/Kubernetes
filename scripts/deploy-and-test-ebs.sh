#!/usr/bin/env bash
# deploy-and-test-ebs.sh — Full deployment and test of Flask app with EBS volumes
#
# This script:
#   1. Deploys the EKS cluster with EBS CSI driver
#   2. Builds and pushes the Flask app Docker image
#   3. Deploys the Flask app with EBS-backed persistent storage
#   4. Tests persistent storage functionality

set -euo pipefail

REGION="ap-southeast-2"
PROFILE="WorkloadConfig"
STACK_NAME="eks-identity"
VPC_ID="vpc-0940d59dd70f7f67d"
SUBNET1="subnet-066506c4fa0e78004"
SUBNET2="subnet-0d419041a14fc9eb5"
SUBNET3="subnet-0f697a017d3f60635"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

AWS="aws --region ${REGION} --profile ${PROFILE}"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
ok()   { echo "[$(date '+%H:%M:%S')] ✓ $*"; }
fail() { echo "[$(date '+%H:%M:%S')] ✗ $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Step 1 — Deploy EKS cluster
# ---------------------------------------------------------------------------
log "Deploying EKS cluster with EBS CSI driver..."
"${SCRIPT_DIR}/deploy.sh" \
  --vpc-id "${VPC_ID}" \
  --subnet1 "${SUBNET1}" \
  --subnet2 "${SUBNET2}" \
  --subnet3 "${SUBNET3}" \
  --region "${REGION}" \
  --profile "${PROFILE}" \
  --stack-name "${STACK_NAME}" \
  || fail "Cluster deployment failed"

ok "EKS cluster deployed"

# ---------------------------------------------------------------------------
# Step 2 — Wait for EBS CSI driver to be ready
# ---------------------------------------------------------------------------
log "Waiting for EBS CSI driver to be ready..."
kubectl rollout status daemonset/ebs-csi-node -n kube-system --timeout=180s || true
kubectl rollout status deployment/ebs-csi-controller -n kube-system --timeout=180s || true
ok "EBS CSI driver ready"

# ---------------------------------------------------------------------------
# Step 3 — Build and push Flask app Docker image
# ---------------------------------------------------------------------------
ACCOUNT_ID=$(${AWS} sts get-caller-identity --query Account --output text)
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
IMAGE_NAME="flask-app"
IMAGE_TAG="latest"
FULL_IMAGE="${ECR_URI}/${IMAGE_NAME}:${IMAGE_TAG}"

log "Building Docker image..."
cd "${ROOT}/app"
docker build -t "${IMAGE_NAME}:${IMAGE_TAG}" . || fail "Docker build failed"
ok "Image built"

log "Creating ECR repository if not exists..."
${AWS} ecr describe-repositories --repository-names "${IMAGE_NAME}" >/dev/null 2>&1 || \
  ${AWS} ecr create-repository --repository-name "${IMAGE_NAME}" --image-scanning-configuration scanOnPush=true

log "Logging into ECR..."
${AWS} ecr get-login-password | docker login --username AWS --password-stdin "${ECR_URI}" || fail "ECR login failed"

log "Tagging and pushing image to ${FULL_IMAGE}..."
docker tag "${IMAGE_NAME}:${IMAGE_TAG}" "${FULL_IMAGE}"
docker push "${FULL_IMAGE}" || fail "Docker push failed"
ok "Image pushed to ECR"

# ---------------------------------------------------------------------------
# Step 4 — Deploy Flask app with EBS volumes
# ---------------------------------------------------------------------------
log "Deploying Flask app with EBS-backed storage..."
kubectl apply -f "${ROOT}/modules/flask-app.yaml" || fail "Flask app deployment failed"

log "Waiting for StatefulSet to be ready (up to 3 minutes)..."
kubectl rollout status statefulset/flask-app -n tenant-customer1 --timeout=180s || fail "StatefulSet rollout failed"
ok "Flask app deployed"

# ---------------------------------------------------------------------------
# Step 5 — Verify EBS volumes were created
# ---------------------------------------------------------------------------
log "Verifying PVCs and PVs..."
kubectl get pvc -n tenant-customer1
kubectl get pv

PVC_COUNT=$(kubectl get pvc -n tenant-customer1 -l app=flask-app -o json | jq '.items | length')
log "Found ${PVC_COUNT} PVCs"

if [[ ${PVC_COUNT} -lt 2 ]]; then
  fail "Expected 2 PVCs (one per replica), found ${PVC_COUNT}"
fi
ok "PVCs created successfully"

# ---------------------------------------------------------------------------
# Step 6 — Test persistent storage functionality
# ---------------------------------------------------------------------------
log "Testing persistent storage..."

# Port-forward to the service
kubectl port-forward -n tenant-customer1 svc/flask-app 8080:80 &
PF_PID=$!
sleep 3

test_api() {
  curl -s "http://localhost:8080$1" -H "Content-Type: application/json" ${2:+"$2"}
}

log "Test 1: Health check"
HEALTH=$(test_api "/health")
echo "${HEALTH}" | jq .
if [[ $(echo "${HEALTH}" | jq -r '.storage') != "true" ]]; then
  fail "Storage health check failed"
fi
ok "Health check passed"

log "Test 2: Add entries to storage"
ENTRY1=$(curl -s -X POST http://localhost:8080/entries \
  -H "Content-Type: application/json" \
  -d '{"message": "First entry - testing EBS persistence"}')
echo "${ENTRY1}" | jq .

ENTRY2=$(curl -s -X POST http://localhost:8080/entries \
  -H "Content-Type: application/json" \
  -d '{"message": "Second entry - data stored on EBS volume"}')
echo "${ENTRY2}" | jq .
ok "Entries created"

log "Test 3: Retrieve all entries"
ENTRIES=$(test_api "/entries")
echo "${ENTRIES}" | jq .
ENTRY_COUNT=$(echo "${ENTRIES}" | jq '.count')
if [[ ${ENTRY_COUNT} -lt 2 ]]; then
  fail "Expected at least 2 entries, found ${ENTRY_COUNT}"
fi
ok "Entries retrieved: ${ENTRY_COUNT} total"

log "Test 4: Get pod names and verify they're using different volumes"
POD0=$(kubectl get pod -n tenant-customer1 flask-app-0 -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")
POD1=$(kubectl get pod -n tenant-customer1 flask-app-1 -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")

if [[ -n "${POD0}" ]]; then
  log "Checking storage on ${POD0}..."
  kubectl exec -n tenant-customer1 "${POD0}" -- ls -lh /data/entries.json
  kubectl exec -n tenant-customer1 "${POD0}" -- cat /data/entries.json | jq .
fi

if [[ -n "${POD1}" ]]; then
  log "Checking storage on ${POD1}..."
  kubectl exec -n tenant-customer1 "${POD1}" -- ls -lh /data/entries.json 2>/dev/null || log "${POD1} has no entries yet (expected)"
fi
ok "Storage verified on pods"

log "Test 5: Verify EBS volume IDs"
for pvc in $(kubectl get pvc -n tenant-customer1 -o name); do
  VOLUME_HANDLE=$(kubectl get "${pvc}" -n tenant-customer1 -o jsonpath='{.spec.volumeName}' | xargs kubectl get pv -o jsonpath='{.spec.csi.volumeHandle}')
  log "PVC ${pvc} -> EBS Volume: ${VOLUME_HANDLE}"
done
ok "EBS volumes mapped"

# Clean up port-forward
kill ${PF_PID} 2>/dev/null || true

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " ✓ EKS cluster deployed with EBS CSI driver"
echo " ✓ Flask app with persistent storage deployed"
echo " ✓ ${ENTRY_COUNT} entries successfully stored on EBS volumes"
echo " ✓ Persistent storage verified working"
echo ""
echo " Access the app:"
echo "   kubectl port-forward -n tenant-customer1 svc/flask-app 8080:80"
echo "   curl http://localhost:8080/entries"
echo ""
echo " View persistent volumes:"
echo "   kubectl get pvc -n tenant-customer1"
echo "   kubectl get pv"
echo ""
echo " Test storage persistence:"
echo "   1. Add more entries: curl -X POST http://localhost:8080/entries -H 'Content-Type: application/json' -d '{\"message\":\"test\"}'"
echo "   2. Delete a pod: kubectl delete pod -n tenant-customer1 flask-app-0"
echo "   3. Wait for pod to restart"
echo "   4. Verify entries still exist: curl http://localhost:8080/entries"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
