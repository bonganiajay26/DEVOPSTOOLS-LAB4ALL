# Phase 3 — Diagnose (structured hypothesis testing)

## The Rule: Hypothesis → Evidence → 10 Minutes → Pivot

```
WRONG approach:
  1. See a suspicious log line
  2. Spend 45 minutes going deeper and deeper
  3. Realize it was a red herring
  4. Start fresh with 45 minutes wasted

RIGHT approach:
  1. State hypothesis explicitly: "I think the DB is slow"
  2. Set 10-minute timer
  3. Gather confirming/disconfirming evidence
  4. If confirmed: fix it
  5. If not confirmed in 10 min: state next hypothesis and pivot
```

---

## Start from the Symptom, Work Backward

```
SYMPTOM: Users see errors / slow responses
         │
         ▼
LAYER 1: Load Balancer / Ingress
         (Is traffic reaching the service?)
         kubectl describe ingress
         kubectl get endpoints
         │
         ▼
LAYER 2: Application pods
         (Are pods running and healthy?)
         kubectl get pods
         kubectl logs --previous
         │
         ▼
LAYER 3: Application dependencies
         (DB, cache, message queue, external APIs)
         Test each connection individually
         │
         ▼
LAYER 4: Infrastructure
         (Node resources, disk, network)
         kubectl top nodes
         kubectl describe node
         │
         ▼
ROOT CAUSE identified at the layer where the failure originates
```

---

## Distributed Tracing — The 10x Speed-Up

> "Before distributed tracing, we'd grep through logs from 5 different services.
> After Jaeger, we find the slow span in 90 seconds." — Production SRE truth

```bash
# Jaeger: find slow traces for payment endpoint
# Open Jaeger UI
kubectl port-forward svc/jaeger-query 16686:16686 -n tracing &

# In the UI:
# Service: payment-api
# Operation: POST /api/v1/checkout
# Min Duration: 2s      ← filter to slow requests only
# Time: last 15 min
# → Click on a failing trace
# → See EXACTLY which span is slow (DB query? External API? Internal service?)

# Programmatic trace search (Jaeger API)
curl "http://localhost:16686/api/traces?\
service=payment-api&\
operation=POST%20%2Fapi%2Fv1%2Fcheckout&\
minDuration=2000000&\
limit=5" | python3 -m json.tool | \
  grep -E "operationName|duration|error"
```

---

## Hypothesis Testing Playbook

### Hypothesis 1: Recent deployment broke something

```bash
# Evidence checklist:
# □ When did errors start? (Prometheus: error rate timeline)
# □ Was there a deployment in the 30 min before?
# □ Does rollback restore the service?

# Check deployment timing
kubectl rollout history deployment -A --no-headers | \
  awk '{print $1, $2, $3}' | column -t

# Correlate: did error rate spike after a deployment?
# Check Prometheus at the time of the deployment

# CONFIRMING: errors started within 10 min of deployment
# ACTION: rollback immediately
bash scripts/04-safe-rollback.sh payment-api production
```

### Hypothesis 2: Database is the bottleneck

```bash
# Evidence checklist:
# □ DB connection count normal?
# □ Query latency elevated?
# □ Any long-running queries blocking others?
# □ Disk I/O saturated on DB node?

# Connection count (PostgreSQL)
kubectl exec -it postgres-0 -n database -- \
  psql -U postgres -c "SELECT count(*) FROM pg_stat_activity;"

# Slow queries (> 5 seconds)
kubectl exec -it postgres-0 -n database -- \
  psql -U postgres -c "
    SELECT pid, now() - query_start AS duration, state, query
    FROM pg_stat_activity
    WHERE state = 'active'
    AND query_start < now() - interval '5 seconds'
    ORDER BY duration DESC;"

# Table bloat / vacuum needed?
kubectl exec -it postgres-0 -n database -- \
  psql -U postgres -c "
    SELECT relname, n_dead_tup, n_live_tup,
           round(n_dead_tup::numeric/NULLIF(n_live_tup,0)*100, 1) as dead_pct
    FROM pg_stat_user_tables
    WHERE n_dead_tup > 10000
    ORDER BY n_dead_tup DESC;"

# Prometheus: DB metrics
# pg_stat_database_tup_fetched — rows fetched
# pg_locks_count               — lock wait
# pg_stat_bgwriter_buffers_alloc — I/O pressure
```

### Hypothesis 3: External dependency is down

```bash
# Evidence checklist:
# □ Which external APIs does this service call?
# □ Are those APIs returning errors?
# □ Is the circuit breaker open?

# Check external API health from inside the pod
kubectl exec -it \
  $(kubectl get pod -l app=payment-api -n production -o name | head -1) \
  -n production -- \
  curl -sv --max-time 5 https://api.stripe.com/v1/charges 2>&1 | \
  grep -E "< HTTP|connect to|timeout"

# Check circuit breaker state (if using Resilience4j / Hystrix)
kubectl exec -it \
  $(kubectl get pod -l app=payment-api -n production -o name | head -1) \
  -n production -- \
  curl -s http://localhost:8080/actuator/circuitbreakers | python3 -m json.tool

# Check Prometheus: external_api_requests_total
# If external_api_requests_total{status="timeout"} is rising → external dependency
```

### Hypothesis 4: Pod resource exhaustion (CPU/Memory)

```bash
# Evidence checklist:
# □ Pods being throttled or OOMKilled?
# □ CPU usage at 100% of limit?
# □ Memory usage near limit?

kubectl top pods -n production --sort-by=memory
kubectl top pods -n production --sort-by=cpu

# CPU throttling: check if throttled_time is high
kubectl exec \
  $(kubectl get pod -l app=payment-api -n production -o name | head -1) \
  -n production -- \
  cat /sys/fs/cgroup/cpu/cpu.stat | grep throttled

# Memory trend (are pods near OOMKill?)
# See oomkilled-debug/ for full analysis
```

### Hypothesis 5: Network / DNS issue

```bash
# Evidence checklist:
# □ Can pods reach each other?
# □ DNS resolution working?
# □ NetworkPolicy blocking traffic?

# DNS test from affected pod
kubectl exec -it \
  $(kubectl get pod -l app=payment-api -n production -o name | head -1) \
  -n production -- \
  nslookup postgres.database.svc.cluster.local

# TCP connectivity test
kubectl exec -it \
  $(kubectl get pod -l app=payment-api -n production -o name | head -1) \
  -n production -- \
  nc -zv postgres.database.svc.cluster.local 5432

# Network policies blocking?
kubectl get networkpolicy -n production -o yaml | \
  grep -E "podSelector|namespaceSelector|ports"
```

---

## Hypothesis Ranking (by frequency — check these first)

```
Rank  Hypothesis                           Frequency at VersatileCommerce
────────────────────────────────────────────────────────────────────────
#1    Bad deployment (config change)            42%
#2    Database: slow queries / connections      21%
#3    External API degraded                     14%
#4    Resource exhaustion (CPU/mem/disk)         9%
#5    Network / DNS failure                      7%
#6    Certificate expired                        3%
#7    K8s node failure                           2%
#8    Other                                      2%

→ Always check #1 first: "Was there a deployment in the last 30 min?"
  42% of all incidents are solved by this single question.
```

---

## The 10-Minute Timer Script

```bash
#!/bin/bash
# Run at the start of each hypothesis
HYPOTHESIS="$1"
echo "$(date -u '+%H:%M UTC') — Testing hypothesis: $HYPOTHESIS"
echo "Timer: 10 minutes. If no confirmation → pivot."

# Log to incident channel
# slack-cli send --channel "#inc-$(date +%Y%m%d)" \
#   "Hypothesis: $HYPOTHESIS — testing now. Timer: 10 min"

# Start countdown
sleep 600 && echo "⏰ 10-minute timer expired for: $HYPOTHESIS" && \
  echo "IC: Call the pivot if hypothesis is not confirmed!" &

echo "Timer PID: $! (kill it if hypothesis confirmed early)"
```
