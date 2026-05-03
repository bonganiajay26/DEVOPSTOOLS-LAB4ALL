# Runbook 01 — High Error Rate (5xx Spike)

**Alert**: `AvailabilitySLOFastBurn` OR `job:http_error_rate:ratio5m > 0.05`  
**Severity**: SEV1 if > 10% | SEV2 if 5–10% | SEV3 if 1–5%  
**Estimated resolution**: 5–15 min (if rollback) | 15–30 min (if diagnosis needed)

---

## Step 1: Triage (2 min)

```bash
# What is the current error rate?
kubectl port-forward svc/prometheus-operated 9090:9090 -n monitoring &
curl -s "http://localhost:9090/api/v1/query" \
  --data-urlencode 'query=sum(rate(http_requests_total{status=~"5.."}[2m]))/sum(rate(http_requests_total[2m]))*100' | \
  python3 -c "import json,sys; print(json.load(sys.stdin)['data']['result'][0]['value'][1], '%')"

# Which services and endpoints?
curl -s "http://localhost:9090/api/v1/query" \
  --data-urlencode 'query=topk(5, sum(rate(http_requests_total{status=~"5.."}[2m])) by (job, handler))' | \
  python3 -m json.tool

# Was there a recent deployment?
kubectl rollout history deployment -A --no-headers | sort -k3 | tail -10
```

---

## Step 2: Fast Mitigation Check

**Did a deployment happen in the last 2 hours?**

```bash
# YES → Rollback immediately. Don't diagnose first.
bash scripts/04-safe-rollback.sh <deployment-name> production
# Monitor for 3 min. If error rate drops → DONE.
```

**Is only one region affected?**

```bash
# Check error rate by region
curl -s "http://localhost:9090/api/v1/query" \
  --data-urlencode 'query=sum(rate(http_requests_total{status=~"5.."}[2m])) by (region)'
# If one region → failover traffic
```

---

## Step 3: Diagnose (if no fast mitigation)

Work backward from symptom through these layers:

### Layer 1: Application pods healthy?

```bash
kubectl get pods -n production | grep -v Running
kubectl logs -l app=<service> -n production --since=5m --tail=100 | \
  grep -iE "error|exception|timeout|panic"
kubectl logs -l app=<service> -n production --previous 2>/dev/null | tail -50
```

**Common findings:**
- `connection refused` → downstream service down → check dependencies
- `timeout` → slow dependency → check DB, external APIs
- `out of memory` → OOMKill → see `oomkilled-debug/` runbook
- Java `OutOfMemoryError: Java heap space` → increase -Xmx or memory limit

### Layer 2: Database healthy?

```bash
kubectl exec -it postgres-0 -n database -- \
  psql -U postgres -c "SELECT count(*) FROM pg_stat_activity;"

kubectl exec -it postgres-0 -n database -- \
  psql -U postgres -c "
    SELECT pid, state, wait_event_type, now()-query_start AS duration, left(query,60) AS query
    FROM pg_stat_activity
    WHERE state = 'active'
    ORDER BY duration DESC LIMIT 10;"
```

**If connection count > 80% of max_connections** → connection pool exhaustion
```bash
# Kill idle connections immediately
kubectl exec -it postgres-0 -n database -- \
  psql -U postgres -c "
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE state = 'idle'
    AND query_start < now() - interval '5 minutes';"
```

### Layer 3: External API dependency down?

```bash
# From inside the affected pod
kubectl exec -it \
  $(kubectl get pod -l app=<service> -n production -o name | head -1) \
  -n production -- \
  curl -sv --max-time 5 https://external-api.com/health
```

### Layer 4: Resource exhaustion?

```bash
kubectl top pods -n production --sort-by=cpu | head -10
kubectl top nodes
```

---

## Step 4: Mitigate

| Root Cause | Mitigation |
|-----------|------------|
| Bad deployment | `kubectl rollout undo deployment/<name> -n production` |
| DB connection exhaustion | Kill idle connections + rolling restart app |
| External API down | Enable circuit breaker / degraded mode |
| CPU throttling | `kubectl scale deployment <name> --replicas=20 -n production` |
| OOMKill | Increase memory limit (see oomkilled-debug runbook) |
| Certificate expired | Annotate cert to force renewal: see runbook 08 |

---

## Step 5: Verify

```bash
# Error rate back to baseline?
watch -n5 'curl -s "http://localhost:9090/api/v1/query" \
  --data-urlencode "query=sum(rate(http_requests_total{status=~\"5..\"}[1m]))/sum(rate(http_requests_total[1m]))*100" | \
  python3 -c "import json,sys; print(json.load(sys.stdin)[\"data\"][\"result\"][0][\"value\"][1], \"%\")"'

# Should be < 0.1% within 3 minutes of mitigation
```

---

## Escalation

- **15 min**: Not mitigated → page Engineering VP
- **30 min**: Not mitigated → page CTO
- **Revenue system**: Page Customer Success immediately
