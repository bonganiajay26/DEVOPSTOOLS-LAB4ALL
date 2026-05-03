# Phase 4 — Mitigate (Restore Service Fast)

## The Prime Directive

> **Restore service first. Find root cause second.**
>
> A perfect diagnosis while users are down is worse than a quick rollback
> that gets users back in 2 minutes. You can always diagnose a working system.
> You cannot recover revenue lost during unnecessary downtime.

---

## Mitigation Toolkit (fastest to slowest)

### Option A: Rollback Last Deployment (< 2 min) ← Default first choice

```bash
# This is the SAFE DEFAULT for any incident where a deployment
# happened in the last 2 hours.

# Check deployment history
kubectl rollout history deployment/payment-api -n production
# REVISION  CHANGE-CAUSE
# 5         Deployed v2.3.1 at 14:15 UTC   ← incident started at 14:32
# 4         Deployed v2.3.0 at 09:00 UTC   ← this was working

# Rollback to previous version (takes ~60–90 seconds)
bash scripts/04-safe-rollback.sh payment-api production

# What the script does:
# 1. Checks current revision and records it (for documentation)
# 2. Runs: kubectl rollout undo deployment/payment-api -n production
# 3. Watches rollout: kubectl rollout status deployment/payment-api --timeout=3m
# 4. Runs smoke test: curl -sf https://api.company.com/health
# 5. Reports: "Rollback complete — error rate check in 60 seconds"

# After rollback: watch error rate recover
watch -n5 'kubectl top pods -n production -l app=payment-api'
```

### Option B: Feature Flag Kill Switch (< 30 seconds)

```bash
# If the incident is caused by a specific feature, disable the flag
# without a deployment.

# LaunchDarkly / Unleash / custom feature flag
# Change flag via CLI, API, or dashboard

# Example with ConfigMap-based flags
kubectl patch configmap feature-flags -n production \
  --type=merge \
  -p '{"data":{"NEW_CHECKOUT_FLOW": "false"}}'

# Rolling restart to pick up new flag (if app doesn't hot-reload)
kubectl rollout restart deployment/checkout-service -n production
```

### Option C: Traffic Failover to Healthy Region (< 5 min)

```bash
# If us-east-1 is down but us-west-2 is healthy:

# AWS Route53: shift all traffic to us-west-2
aws route53 change-resource-record-sets \
  --hosted-zone-id Z123ABCDEF \
  --change-batch '{
    "Changes": [{
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "api.company.com",
        "Type": "CNAME",
        "TTL": 60,
        "ResourceRecords": [{"Value": "api-us-west-2.company.com"}]
      }
    }]
  }'

# Kubernetes: update Ingress weight
# (if using nginx-ingress with canary annotations)
kubectl annotate ingress payment-api -n production \
  nginx.ingress.kubernetes.io/canary-weight="100" \
  --overwrite
```

### Option D: Emergency Scale-Up (< 3 min)

```bash
# If the issue is pods overwhelmed by traffic:

# Scale up immediately (HPA takes too long in a crisis)
kubectl scale deployment payment-api --replicas=20 -n production

# Watch pods come up
kubectl get pods -n production -l app=payment-api -w

# After incident: set it back to a sensible number
# and fix the underlying capacity issue
```

### Option E: Circuit Breaker / Degraded Mode (< 2 min)

```bash
# If an external dependency is down (e.g., Stripe),
# switch to degraded mode (queue payments, show maintenance message)

# Toggle via ConfigMap
kubectl patch configmap app-config -n production \
  --type=merge \
  -p '{"data":{
    "PAYMENT_MODE": "degraded",
    "SHOW_MAINTENANCE_BANNER": "true"
  }}'

# Users see: "Payments temporarily unavailable. Your cart is saved."
# Better than: HTTP 500
```

### Option F: Force-Restart Crashing Pods (< 2 min)

```bash
# For CrashLoopBackOff / OOMKilled pods with no obvious cause:

# Delete pods — Deployment recreates them immediately
kubectl delete pods -n production -l app=payment-api \
  --field-selector=status.phase=Failed

# Or rolling restart (zero-downtime)
kubectl rollout restart deployment/payment-api -n production
kubectl rollout status deployment/payment-api -n production
```

---

## Post-Mitigation Verification

Never declare "mitigated" until you verify with data. Not vibes.

```bash
# 1. Error rate back to baseline?
curl -s "http://localhost:9090/api/v1/query" \
  --data-urlencode 'query=sum(rate(http_requests_total{status=~"5.."}[2m]))' | \
  python3 -c "import json,sys; r=json.load(sys.stdin); val=float(r['data']['result'][0]['value'][1]); print(f'Error rate: {val:.4f}/s', '✅ OK' if val < 0.01 else '❌ STILL HIGH')"

# 2. SLO burn rate below 1x (normal)?
curl -s "http://localhost:9090/api/v1/query" \
  --data-urlencode 'query=(sum(rate(http_requests_total{status=~"5.."}[5m]))/sum(rate(http_requests_total[5m])))/0.001' | \
  python3 -c "import json,sys; r=json.load(sys.stdin); val=float(r['data']['result'][0]['value'][1]); print(f'Burn rate: {val:.1f}x', '✅ Normal' if val < 2 else '❌ STILL BURNING')"

# 3. All pods running and ready?
kubectl get pods -n production | grep -v "Running\|Completed" | \
  grep -c "" && echo "Unhealthy pods found!" || echo "✅ All pods healthy"

# 4. End-to-end smoke test
curl -sf https://api.company.com/health && echo "✅ Health check passed" || echo "❌ Health check FAILED"
curl -sf https://api.company.com/api/v1/status && echo "✅ API responding" || echo "❌ API still failing"

# 5. Wait and observe for 5 minutes before declaring success
echo "Monitoring for 5 minutes..."
for i in $(seq 1 5); do
  ERRORS=$(curl -sf "http://localhost:9090/api/v1/query" \
    --data-urlencode 'query=sum(rate(http_requests_total{status=~"5.."}[1m]))' | \
    python3 -c "import json,sys; print(float(json.load(sys.stdin)['data']['result'][0]['value'][1]))")
  echo "Min $i: $ERRORS errors/sec"
  sleep 60
done
```

---

## Mitigation Announcement Templates

### When mitigation applied (before confirmed)
```
[HH:MM UTC] STATUS UPDATE
We have applied a mitigation (rolled back deployment v2.3.1).
Monitoring for stability. Early indicators look positive.
Will confirm resolution in 5 minutes.
```

### When confirmed stable
```
[HH:MM UTC] MITIGATED ✅
Service has been restored. Error rate back to baseline.
Root cause: [brief description or "under investigation"]
Total impact duration: ~XX minutes
Post-mortem will be published within 48 hours.
```

### Update status page
```
Resolved — [HH:MM UTC]
The payment service disruption has been resolved.
All systems are operating normally.
We are conducting a post-mortem to prevent recurrence.
We apologize for the impact to your service.
```
