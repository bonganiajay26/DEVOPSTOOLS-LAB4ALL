# Lab 03: Full Production Incident Simulation

**Difficulty**: Advanced | **Time**: 90 minutes  
**Goal**: Experience a realistic production incident from alert to post-mortem.

---

## Scenario

**2:47 AM UTC** — PagerDuty fires.  
Alert: `SLOAvailabilityBudgetBurning` — API error rate 15%, burning budget 150x.  
Last deployment was 4 hours ago.

---

## Part 1: Incident Response Simulation

```bash
# ── Simulate the cluster state ────────────────────────────────
kind create cluster --name incident-lab

# Deploy "broken" application
cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: production
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-service
  namespace: production
spec:
  replicas: 3
  selector:
    matchLabels:
      app: api-service
  template:
    metadata:
      labels:
        app: api-service
    spec:
      containers:
      - name: api
        image: nginx:alpine
        ports:
        - containerPort: 80
        readinessProbe:
          httpGet:
            path: /healthz
            port: 80
          initialDelaySeconds: 5
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 200m
            memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: api-service
  namespace: production
spec:
  selector:
    app: api-service
  ports:
  - port: 80
EOF

kubectl wait --for=condition=Ready pod -l app=api-service -n production --timeout=60s

# Simulate incident: cause one pod to crash
kubectl exec -n production \
  $(kubectl get pod -l app=api-service -n production -o name | head -1) \
  -- sh -c "kill 1" 2>/dev/null || true
```

---

## Part 2: Alert Received — Start the Clock

```bash
# STEP 1: Acknowledge (< 5 minutes)
echo "$(date -u): Incident acknowledged"
echo "Starting investigation..."

# STEP 2: Assess blast radius
echo ""
echo "=== BLAST RADIUS ASSESSMENT ==="
kubectl get pods -n production
kubectl get nodes

# Error rate
echo ""
echo "=== CURRENT STATE ==="
kubectl get deployment api-service -n production
kubectl describe deployment api-service -n production | grep -A10 "Conditions:"
```

---

## Part 3: Investigation Workflow

```bash
# ── 3a. Check recent deployments ─────────────────────────────
echo "=== Recent Deployments ==="
kubectl rollout history deployment/api-service -n production

# ── 3b. Check pod status ─────────────────────────────────────
echo ""
echo "=== Pod Status ==="
kubectl get pods -n production -o wide

# Find restarting pods
kubectl get pods -n production | awk 'NR>1 && $4>0 {print "RESTART:", $1, "restarts:", $4}'

# ── 3c. Check logs ────────────────────────────────────────────
echo ""
echo "=== Recent Logs (errors) ==="
for pod in $(kubectl get pods -n production -l app=api-service -o name); do
    echo "--- $pod ---"
    kubectl logs $pod -n production --tail=20 2>/dev/null | grep -iE "error|fatal|panic|exception" || echo "(no errors in logs)"
done

# ── 3d. Check events (often the most revealing) ───────────────
echo ""
echo "=== Recent Events ==="
kubectl get events -n production \
    --sort-by='.lastTimestamp' \
    --field-selector type=Warning \
    | tail -20

# ── 3e. Check resource usage ─────────────────────────────────
echo ""
echo "=== Resource Usage ==="
kubectl top pods -n production 2>/dev/null || echo "metrics-server not available"
```

---

## Part 4: Diagnose Root Cause

```bash
# Run through the diagnostic decision tree
echo "=== DIAGNOSTIC DECISION TREE ==="

# Check 1: Are pods running?
RUNNING=$(kubectl get pods -n production -l app=api-service \
    --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
DESIRED=$(kubectl get deployment api-service -n production \
    -o jsonpath='{.spec.replicas}')

echo "Running pods: $RUNNING / $DESIRED desired"

if [ "$RUNNING" -lt "$DESIRED" ]; then
    echo ">>> Pod count issue detected!"
    
    # Find the problem pod
    PROBLEM_POD=$(kubectl get pods -n production --no-headers | \
        awk '$3 != "Running" || $4 > 3 {print $1}' | head -1)
    
    if [ -n "$PROBLEM_POD" ]; then
        echo ""
        echo ">>> Investigating problem pod: $PROBLEM_POD"
        
        # Get last state
        echo "Last state:"
        kubectl get pod $PROBLEM_POD -n production \
            -o jsonpath='{.status.containerStatuses[0].lastState}' | python3 -m json.tool

        # Exit code
        EXIT_CODE=$(kubectl get pod $PROBLEM_POD -n production \
            -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}')
        echo "Exit code: $EXIT_CODE"
        
        case "$EXIT_CODE" in
            "0")  echo "Clean exit - expected termination" ;;
            "1")  echo "Application error - check logs" ;;
            "137") echo "OOM Kill or SIGKILL - check memory usage" ;;
            "139") echo "Segfault - application bug" ;;
            "143") echo "SIGTERM - graceful shutdown not handled" ;;
            *)    echo "Unknown exit code: $EXIT_CODE" ;;
        esac

        # Previous logs
        echo ""
        echo "Previous container logs:"
        kubectl logs $PROBLEM_POD -n production --previous --tail=30 2>/dev/null || \
            echo "(no previous logs available)"
    fi
fi

# Check 2: Service endpoints populated?
echo ""
echo "=== Service Endpoints ==="
kubectl get endpoints api-service -n production
# Empty endpoints = service selector mismatch OR no ready pods

# Check 3: Deployment selector matches pod labels?
echo ""
echo "=== Label Matching ==="
echo "Service selector:"
kubectl get svc api-service -n production -o jsonpath='{.spec.selector}' | python3 -m json.tool

echo "Pod labels:"
kubectl get pods -n production -l app=api-service -o jsonpath='{.items[0].metadata.labels}' | python3 -m json.tool
```

---

## Part 5: Mitigation and Recovery

```bash
echo "=== MITIGATION ACTIONS ==="

# Action 1: Scale up to handle load with remaining pods
echo "Scaling deployment to 5 replicas..."
kubectl scale deployment api-service -n production --replicas=5
kubectl rollout status deployment/api-service -n production

# Action 2: If recent deployment is suspect — rollback
REVISION_COUNT=$(kubectl rollout history deployment/api-service -n production | wc -l)
if [ "$REVISION_COUNT" -gt 2 ]; then
    echo ""
    echo "Rolling back to previous revision..."
    kubectl rollout undo deployment/api-service -n production
    kubectl rollout status deployment/api-service -n production
fi

# Action 3: Verify recovery
echo ""
echo "=== VERIFICATION ==="
kubectl get pods -n production -l app=api-service
kubectl get endpoints api-service -n production

# Test service response
kubectl run healthcheck --image=curlimages/curl --rm -it \
    --restart=Never \
    -- curl -s http://api-service.production.svc.cluster.local/healthz \
    && echo "✅ Health check PASSED" \
    || echo "❌ Health check FAILED"
```

---

## Part 6: Write the Post-Mortem

```bash
cat > post-mortem-$(date +%Y%m%d).md << 'EOF'
# Post-Mortem: API Service Outage — $(date +%Y-%m-%d)

**Duration**: 23 minutes  
**Severity**: SEV-1  
**Impact**: 15% error rate, ~500 users affected  

## Timeline (UTC)
| Time  | Event |
|-------|-------|
| 02:47 | Alert fired: error_rate=15%, SEV-1 |
| 02:52 | On-call acknowledged |
| 02:55 | Confirmed pod count 1/3 running |
| 03:01 | Identified OOMKilled pod |
| 03:05 | Scaled to 5 replicas, error rate → 0% |
| 03:08 | Rolled back deploy, pods stabilized |
| 03:10 | All-clear declared |

## Root Cause
API pod was OOMKilled (exit 137) due to memory limit of 256Mi being
exceeded after deploy v2.4.1 introduced a memory-intensive caching layer.
With 2 of 3 pods down, the remaining pod couldn't handle full traffic.

## Contributing Factors
1. Memory limit set too low (256Mi, service needs ~400Mi with new caching)
2. No load test in staging (staging has 512Mi limits, wider margin)
3. Readiness probe passed even though pod was about to OOM

## Impact
- 15% request failure rate for 23 minutes
- ~500 users saw 503 errors
- No data loss or corruption

## What Went Well
- Alert fired within 30 seconds of threshold breach
- Runbook was accurate and helped quickly
- Rollback was straightforward
- Clear deployment history made root cause obvious

## Action Items
| # | Action | Owner | Due | P |
|---|--------|-------|-----|---|
| 1 | Increase memory limit to 512Mi | @backend | Today | P1 |
| 2 | Add memory load test to staging CI | @platform | Week 1 | P1 |
| 3 | Add canary deployment to catch OOM before full rollout | @platform | Sprint | P2 |
| 4 | Tune readiness probe to detect memory pressure | @backend | Sprint | P2 |
| 5 | Add VPA recommendation to deployment process | @platform | Q2 | P3 |

## Blameless Statement
This incident was caused by a gap in our release process
(no memory load testing), not individual error.
EOF

echo "Post-mortem written: post-mortem-$(date +%Y%m%d).md"
cat post-mortem-$(date +%Y%m%d).md
```

---

## Cleanup

```bash
kind delete cluster --name incident-lab
rm -f post-mortem-*.md
```

## What You Learned

- [x] Structured incident response process (acknowledge → triage → investigate → fix)
- [x] Reading exit codes to identify pod failure cause
- [x] Service endpoint debugging (empty endpoints = no ready pods)
- [x] Immediate mitigation: scale up + rollback
- [x] Writing blameless post-mortems with concrete action items
- [x] Tracking timeline for post-mortem analysis
