# Phase 2 — Triage (5–15 minutes)

## Goal
Answer three questions before spending time diagnosing:
1. **How bad is it?** (blast radius)
2. **Is it getting worse or stabilizing?** (trajectory)
3. **Can we restore without diagnosis?** (fast mitigation)

---

## The Blast Radius Assessment

Run this immediately. Don't debug until you know the scope.

```bash
bash scripts/02-blast-radius.sh --namespace production

# Output:
# ═══════════════════════════════════════════════
# BLAST RADIUS REPORT — 14:35 UTC
# ═══════════════════════════════════════════════
# Error rate:        15.3%  (SLO target: 0.1%)
# Affected requests: ~1,530/min
# Affected services: payment-api, checkout-ui
# Healthy services:  auth, product-catalog, search
# Pods failing:      3 of 10 payment-api pods
# DB status:         HEALTHY (connections normal)
# Error type:        HTTP 503 (upstream timeout)
# Region:            us-east-1 only (us-west-2 OK)
# Customer impact:   ~2,400 users in last 5 min
# Error budget:      CRITICAL (burning 150x)
```

---

## Three Triage Questions

### Question 1: How many users are affected?

```bash
# Active error rate right now
kubectl port-forward svc/prometheus-operated 9090:9090 -n monitoring &

# Query: requests failing per second
curl -s "http://localhost:9090/api/v1/query" \
  --data-urlencode \
  'query=sum(rate(http_requests_total{status=~"5.."}[2m]))' | \
  python3 -c "import json,sys; r=json.load(sys.stdin); print(r['data']['result'][0]['value'][1], 'req/s failing')"

# Which endpoints are worst?
curl -s "http://localhost:9090/api/v1/query" \
  --data-urlencode \
  'query=topk(5, sum(rate(http_requests_total{status=~"5.."}[2m])) by (handler))' | \
  python3 -m json.tool
```

### Question 2: Trajectory — getting worse or stabilizing?

```bash
# Compare error rate now vs 5 min ago
# If NOW > 5_MIN_AGO → escalating (act immediately)
# If NOW ≈ 5_MIN_AGO → stable (you have time to diagnose)
# If NOW < 5_MIN_AGO → recovering (investigate but lower urgency)

# Prometheus: error rate trend (5 min window)
curl -s "http://localhost:9090/api/v1/query_range" \
  --data-urlencode 'query=sum(rate(http_requests_total{status=~"5.."}[1m]))' \
  --data-urlencode "start=$(date -v-10M +%s)" \
  --data-urlencode "end=$(date +%s)" \
  --data-urlencode 'step=60' | \
  python3 -c "
import json, sys
data = json.load(sys.stdin)
values = data['data']['result'][0]['values']
for ts, val in values[-5:]:
    from datetime import datetime
    t = datetime.fromtimestamp(float(ts)).strftime('%H:%M')
    print(f'  {t}: {float(val):.2f} errors/sec')
"
```

### Question 3: Can we restore without diagnosis?

```
Fast mitigation decision tree:

Did it start after a deployment?  (check: kubectl rollout history)
  YES → Rollback immediately. Diagnose root cause after service restored.
        bash scripts/04-safe-rollback.sh <deployment> <namespace>

Is traffic only failing in one region?
  YES → Failover to healthy region.
        Update DNS / Load balancer weights.

Is a specific feature/flag causing it?
  YES → Disable the feature flag (30 seconds to restore).

Are specific pods crashing?
  YES → Delete crashing pods (Deployment restarts them).
        kubectl delete pod -l app=payment-api -n production

Is it a dependency (DB/cache/queue) that has a fallback?
  YES → Enable degraded mode (circuit breaker / cached responses).

NONE OF THE ABOVE?
  → Proceed to Phase 3: Diagnose
```

---

## Triage Cheatsheet

```bash
# ── Most useful triage commands ───────────────────────────────

# What's broken?
kubectl get pods -A | grep -v "Running\|Completed"

# Any recent deployments?
kubectl rollout history deployment -A | sort -k3 | tail -20

# Top errors in logs (last 5 min)
kubectl logs -l app=payment-api -n production --since=5m 2>/dev/null | \
  grep -iE "error|fatal|panic|timeout" | \
  sort | uniq -c | sort -rn | head -10

# Is the database reachable?
kubectl exec -it -n production \
  $(kubectl get pod -l app=payment-api -n production -o name | head -1) \
  -- nc -zv postgres.database.svc.cluster.local 5432

# Service endpoints populated?
kubectl get endpoints -n production | grep -v "^NAME"

# Node resource pressure?
kubectl describe nodes | grep -E "MemoryPressure|DiskPressure" | grep -v "False"

# Recent events (warnings only)
kubectl get events -A --field-selector type=Warning \
  --sort-by='.lastTimestamp' | tail -20
```

---

## The Mitigation-vs-Diagnosis Decision

```
IF service can be restored in < 5 minutes by:
  → Rolling back a deployment
  → Switching to a backup region
  → Disabling a feature flag
  → Restarting crashing pods
  → Scaling up overwhelmed pods

THEN: Restore FIRST. Diagnose AFTER.

Reasoning: Every minute of downtime costs users.
Finding root cause while users are down is an indulgence.
Restore first. Understand why second.
Exception: if mitigation action has HIGH risk of making it worse.

IF no fast mitigation is obvious:
  → Proceed to Phase 3 (Diagnose) immediately.
  → Set 10-minute hypothesis timer.
```
