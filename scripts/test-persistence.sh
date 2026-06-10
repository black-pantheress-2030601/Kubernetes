#!/usr/bin/env bash
# test-persistence.sh — Test EBS volume persistence by deleting a pod and verifying data survives
#
# This script demonstrates that data stored on EBS volumes persists across pod restarts

set -euo pipefail

NAMESPACE="tenant-customer1"
POD_NAME="flask-app-0"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
ok()   { echo "[$(date '+%H:%M:%S')] ✓ $*"; }
fail() { echo "[$(date '+%H:%M:%S')] ✗ $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Step 1 — Add test data
# ---------------------------------------------------------------------------
log "Starting port-forward..."
kubectl port-forward -n "${NAMESPACE}" svc/flask-app 8080:80 &
PF_PID=$!
sleep 3

log "Adding test entries..."
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

ENTRY1=$(curl -s -X POST http://localhost:8080/entries \
  -H "Content-Type: application/json" \
  -d "{\"message\": \"Persistence test - ${TIMESTAMP}\"}")
echo "${ENTRY1}" | jq .

ENTRY2=$(curl -s -X POST http://localhost:8080/entries \
  -H "Content-Type: application/json" \
  -d "{\"message\": \"This data should survive pod deletion\"}")
echo "${ENTRY2}" | jq .

log "Retrieving entries before pod deletion..."
BEFORE=$(curl -s http://localhost:8080/entries)
BEFORE_COUNT=$(echo "${BEFORE}" | jq '.count')
echo "Entries before deletion: ${BEFORE_COUNT}"
echo "${BEFORE}" | jq -r '.entries[] | "\(.id): \(.message) (pod: \(.pod))"'

kill ${PF_PID} 2>/dev/null || true
ok "Test data added (${BEFORE_COUNT} entries)"

# ---------------------------------------------------------------------------
# Step 2 — Delete pod to test persistence
# ---------------------------------------------------------------------------
log "Deleting pod ${POD_NAME} to test persistence..."
kubectl delete pod -n "${NAMESPACE}" "${POD_NAME}" || fail "Pod deletion failed"

log "Waiting for pod to be recreated..."
kubectl wait --for=condition=ready pod -n "${NAMESPACE}" "${POD_NAME}" --timeout=120s || fail "Pod did not become ready"
ok "Pod recreated"

# Give the pod a moment to fully start
sleep 5

# ---------------------------------------------------------------------------
# Step 3 — Verify data persisted
# ---------------------------------------------------------------------------
log "Starting port-forward to recreated pod..."
kubectl port-forward -n "${NAMESPACE}" svc/flask-app 8080:80 &
PF_PID=$!
sleep 3

log "Retrieving entries after pod recreation..."
AFTER=$(curl -s http://localhost:8080/entries)
AFTER_COUNT=$(echo "${AFTER}" | jq '.count')
echo "Entries after pod recreation: ${AFTER_COUNT}"
echo "${AFTER}" | jq -r '.entries[] | "\(.id): \(.message) (pod: \(.pod))"'

kill ${PF_PID} 2>/dev/null || true

# ---------------------------------------------------------------------------
# Step 4 — Verify data integrity
# ---------------------------------------------------------------------------
if [[ ${AFTER_COUNT} -ge ${BEFORE_COUNT} ]]; then
  ok "✓ SUCCESS: Data persisted! (${AFTER_COUNT} entries found)"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " Persistence Test Results:"
  echo "   Before pod deletion: ${BEFORE_COUNT} entries"
  echo "   After pod deletion:  ${AFTER_COUNT} entries"
  echo ""
  echo "   ✓ EBS volume successfully retained data across pod restart"
  echo "   ✓ StatefulSet correctly reattached the same PVC to the new pod"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 0
else
  fail "✗ FAILURE: Data lost! Expected at least ${BEFORE_COUNT} entries, found ${AFTER_COUNT}"
fi
