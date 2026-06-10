# Presentation Notes - EKS Multi-Tenant Cluster

## Demo Script

### Part 1: Show Current State (5 min)
```bash
# Show cluster info
kubectl cluster-info
kubectl get nodes -L customer-id,node-role

# Show namespaces
kubectl get namespaces -l isolation=strict

# Show RBAC setup
kubectl get clusterrole tenant-editor -o yaml
kubectl get rolebindings -n tenant-customer1
```

### Part 2: Deploy Application (3 min)
```bash
# Show the manifest
cat modules/flask-app.yaml

# Deploy
kubectl apply -f modules/flask-app.yaml

# Watch it come up
kubectl get pods,pvc,pv -n tenant-customer1 -w
```

### Part 3: Test Persistence (5 min)
```bash
# Port-forward
kubectl port-forward -n tenant-customer1 svc/flask-app 8080:80

# Add data
curl -X POST http://localhost:8080/entries \
  -H "Content-Type: application/json" \
  -d '{"message":"Demo entry - this will survive pod deletion"}'

# Show data
curl http://localhost:8080/entries | jq .

# Delete pod
kubectl delete pod -n tenant-customer1 flask-app-0

# Wait for recreation
kubectl wait --for=condition=ready pod/flask-app-0 -n tenant-customer1

# Verify data persisted
kubectl port-forward -n tenant-customer1 pod/flask-app-0 8080:5000
curl http://localhost:8080/entries | jq .
```

### Part 4: Show AWS Integration (2 min)
```bash
# Show EBS volumes in AWS
aws ec2 describe-volumes \
  --filters "Name=tag:kubernetes.io/created-for/pvc/name,Values=data-flask-app-*" \
  --query 'Volumes[*].[VolumeId,Size,State,VolumeType,Encrypted]' \
  --output table

# Show node IAM roles
kubectl describe pod -n kube-system ebs-csi-controller-xxx | grep "AWS_ROLE_ARN"
```

---

## Talking Points by Slide

### Slide 3 (Architecture)
**Key Messages:**
- "We've separated platform services from tenant workloads"
- "System nodes run everything needed to keep the cluster healthy"
- "Tenant nodes are dedicated - no mixing of customer workloads"
- "Bottlerocket gives us automatic security patches without manual intervention"

### Slide 5 (Access Control)
**Key Messages:**
- "Teams use their existing AWS roles - no new credentials"
- "The access entry maps AWS identity to Kubernetes groups"
- "RBAC enforces namespace boundaries"
- "We removed dangerous permissions like pod/exec to prevent container escape"

### Slide 7 (Demo)
**Key Messages:**
- "This demonstrates a real-world pattern: stateful applications"
- "Each pod gets its own volume - true data isolation"
- "When a pod crashes or is deleted, Kubernetes reattaches the same volume"
- "This works for databases, message queues, any stateful workload"

### Slide 10 (Gaps)
**Be Honest:**
- "We're production-ready for compute and storage"
- "But we're flying blind without logging and monitoring"
- "This is our top priority for the next sprint"

### Slide 11 (Phase 1 Roadmap)
**Critical Point:**
- "The separate cluster decision is important"
- "Most regulations and compliance frameworks require prod isolation"
- "It's also much easier to test destructive changes in non-prod"

### Slide 16 (Decisions Needed)
**Call to Action:**
- "We need decision #3 (IAM permissions) to move forward efficiently"
- "Currently every infrastructure change requires manual workarounds"
- "Decision #1 (environment strategy) blocks prod onboarding timeline"

---

## Answers to Expected Questions

### Q: "Why not use separate accounts instead of a shared cluster?"
**A:** "Separate accounts give isolation but at high overhead cost:
- Each account needs its own VPC, NAT gateways, load balancers
- Each needs separate monitoring, logging, backup infrastructure
- Management overhead scales linearly with account count
- For our use case (internal teams, moderate security requirements), namespace isolation with RBAC provides sufficient security at much lower cost and complexity"

### Q: "What happens if the cluster goes down?"
**A:** "Current state: Single cluster, multi-AZ. If cluster fails, we rebuild from Infrastructure-as-Code.
Future state: 
- Critical workloads run as StatefulSets with pod disruption budgets
- Backup cluster in same region (DR)
- EBS volumes persist independently of cluster state
- Recovery time: ~15 minutes for cluster, 0 minutes for data"

### Q: "How do we prevent one tenant from using all the resources?"
**A:** "Three layers:
1. Today: Separate node groups - physical isolation
2. Next sprint: ResourceQuotas per namespace (CPU, memory, storage limits)
3. Future: Cost showback - visibility drives behavior

Example ResourceQuota:
- Max 10 pods
- Max 20 CPU cores
- Max 40GB memory
- Max 100GB storage"

### Q: "Can tenants see each other's workloads?"
**A:** "No. Three isolation mechanisms:
1. RBAC - can only access own namespace
2. Node taints - workloads land on dedicated nodes
3. (Future) NetworkPolicies - can't even route traffic cross-namespace

We tested this with the demo - try to access customer2 namespace with customer1 credentials and you get 'Forbidden'."

### Q: "What's the cost compared to separate clusters per team?"
**A:** "Rough numbers:
- Shared cluster: $200-270/tenant/month
- Separate clusters: $500-800/tenant/month

The control plane alone is $73/month per cluster.
NAT gateways add $100+/month per cluster.
Shared cluster becomes more cost-effective at 2+ tenants."

### Q: "Why Bottlerocket instead of Amazon Linux?"
**A:** "Three reasons:
1. Immutable - can't SSH in and make changes that drift
2. Smaller attack surface - only what Kubernetes needs
3. Auto-updates - BRUPOP handles rolling updates, we just watch

For a shared cluster where trust is important, the reduced attack surface is critical."

### Q: "When can we onboard production workloads?"
**A:** "Depends on your risk tolerance:
- Technically ready today for non-sensitive workloads
- Need logging before any production (critical for troubleshooting)
- Need non-prod cluster before prod cluster (blast radius)
- Need NetworkPolicies before sensitive data

Timeline: 4-6 weeks for full production readiness"

### Q: "What about Secrets Manager - you mentioned it's not tested?"
**A:** "We have the add-on installed but haven't validated the full workflow.
Testing plan:
1. Install AWS Secrets Manager CSI driver (1 day)
2. Create test secret in Secrets Manager
3. Mount as volume in pod
4. Verify auto-rotation works
5. Document pattern for teams

Expected completion: Next week"

### Q: "How do we handle different teams needing different Kubernetes versions?"
**A:** "We don't - everyone runs the same version in a shared cluster.
This is actually a feature, not a limitation:
- Consistent behavior across teams
- Single upgrade cycle
- No version compatibility headaches

If a team truly needs a different version (rare), they would need a dedicated cluster."

---

## Key Statistics to Memorize

- **2 EBS volumes** provisioned and tested (5GB each, GP3, encrypted)
- **3 tenant namespaces** configured
- **4 data entries** verified persistent across pod restarts
- **99.9% uptime** target SLA
- **<30 seconds** pod startup time
- **<2 minutes** EBS volume provisioning time
- **$200-270/month** estimated cost per tenant
- **1 day** target for new tenant onboarding (future state)

---

## Recommended Slide Timing (30 min presentation)

- Slides 1-2: 2 min (intro)
- Slides 3-6: 8 min (architecture & security)
- Slide 7 + Demo: 10 min (live demo)
- Slides 8-10: 5 min (current state & gaps)
- Slides 11-15: 10 min (roadmap)
- Slides 16-17: 3 min (decisions & recommendations)
- Slide 18-19: 2 min (metrics & risks)
- Q&A: 10 min

**Total: 50 min with Q&A**

---

## Pre-Demo Checklist

Before presenting, verify:
- [ ] Cluster is accessible: `kubectl get nodes`
- [ ] Flask app is running: `kubectl get pods -n tenant-customer1`
- [ ] Port 8080 is free: `lsof -i :8080`
- [ ] AWS CLI configured: `aws sts get-caller-identity`
- [ ] Have backup slides ready if demo fails
- [ ] Browser open to AWS Console (EC2 volumes page)
- [ ] Terminal font size increased for visibility
- [ ] Demo data cleared (optional): `kubectl exec -n tenant-customer1 flask-app-0 -- rm /data/entries.json`

---

## If Demo Fails - Backup Plan

**Option 1: Show Screenshots**
- Keep screenshots of successful test run
- Walk through what would have happened

**Option 2: Show Pre-Recorded Video**
- Record the demo beforehand
- Play if live demo has issues

**Option 3: Focus on Architecture**
- Skip to Slide 8 (What's Working)
- Show kubectl outputs of pods/pvcs
- Show AWS Console EBS volumes
- Explain what persistence test would show

---

## Post-Presentation Action Items

After presenting, follow up with:

1. **Email Summary**
   - Link to presentation
   - Link to documentation (EBS-STORAGE.md, QUICKSTART-EBS.md)
   - List of decisions needed with deadline
   - Cost estimate spreadsheet

2. **Slack/Teams Message**
   - Demo recording link
   - Thank attendees
   - Open for follow-up questions

3. **Create Jira Tickets**
   - One ticket per Phase 1 roadmap item
   - Link to this presentation
   - Estimate effort (story points)

4. **Schedule Follow-Up**
   - 1-week check-in on decisions
   - Sprint planning to prioritize roadmap
   - Technical deep-dive for interested teams
