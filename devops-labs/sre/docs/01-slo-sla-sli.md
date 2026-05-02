# SLIs, SLOs, SLAs & Error Budgets

## Definitions

```
SLI (Service Level Indicator)
  → A specific measurable metric that represents service health
  → "What we measure"

SLO (Service Level Objective)
  → The target value for an SLI
  → "What we promise to ourselves"
  → Internal commitment. Not contractual.

SLA (Service Level Agreement)
  → Legal/business contract with consequences for breach
  → "What we promise to customers in writing"
  → Should be weaker than SLO (buffer for real-world issues)

Error Budget
  → SLO target - actual performance = how much failure you can afford
  → Error budget = 1 - SLO
```

---

## The Relationship

```
SLO: 99.9% availability
                 ↓
Error budget: 0.1% = 43.8 min/month of allowed downtime
                 ↓
Monitoring: Is current error rate consuming budget faster than planned?
                 ↓
Action: If budget burning fast → stop risky deploys, fix reliability
        If budget unused → deploy more features, run experiments
```

---

## Defining Good SLIs

```
Category         SLI Candidates
────────────────────────────────────────────────────────────
Availability     % of requests that return a successful response
                 = good_requests / total_requests

Latency          % of requests faster than threshold
                 = requests_under_100ms / total_requests

Quality          % of responses with correct data
                 = valid_responses / total_responses

Freshness        % of data updates completed within threshold
                 = updates_within_5min / total_updates

Durability       % of stored data retrievable
                 = successfully_retrieved / stored_records
```

---

## Setting SLO Targets

```
❌ Bad: "99.999% availability"
   Why: Costs enormous engineering effort. Impossible to maintain with any feature velocity.

✅ Good: Base SLOs on user impact + historical performance

Research findings (Google SRE Book):
  - Users notice latency above 100ms
  - Users abandon at 1s
  - 99.9% availability: 8.7 hours downtime/year
  - 99.99% availability: 52 minutes downtime/year

Recommendation by tier:
  Customer-facing critical:  99.9%  (Tier 1)
  Customer-facing standard:  99.5%  (Tier 2)
  Internal services:         99.0%  (Tier 3)
  Dev/batch:                 95.0%  (Tier 4)
```

---

## Error Budget Policy

```
When error budget is healthy (> 50% remaining):
→ Normal deployment velocity
→ Can run experiments and risky changes

When error budget is at risk (< 25% remaining):
→ Reduce deployment frequency
→ Only critical fixes
→ Focus on reliability improvements

When error budget is exhausted (< 0%):
→ Feature freeze
→ All hands on reliability
→ No non-critical deploys until budget replenishes

Formula:
  Monthly error budget = (1 - 0.999) × 30 × 24 × 60 = 43.2 minutes
  Daily error budget = 43.2 / 30 = 1.44 minutes/day
  Budget burn rate = (error_rate / (1 - SLO)) = N× normal
```

---

## Prometheus-Based Error Budget Monitoring

```yaml
# PrometheusRule for SLO monitoring
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: api-slo
spec:
  groups:
  # Recording rules for SLO calculations
  - name: slo-recording
    interval: 1m
    rules:
    # 5m error rate
    - record: job:api_error_rate:ratio5m
      expr: |
        sum(rate(http_requests_total{job="api",status=~"5.."}[5m]))
        /
        sum(rate(http_requests_total{job="api"}[5m]))

    # 30d error rate (for SLO tracking)
    - record: job:api_error_rate:ratio30d
      expr: |
        sum(rate(http_requests_total{job="api",status=~"5.."}[30d]))
        /
        sum(rate(http_requests_total{job="api"}[30d]))

  # Multi-window error budget alerts
  - name: slo-alerts
    rules:
    # Fast burn: consuming 5% of budget in 1h (will exhaust in 20h)
    - alert: ErrorBudgetBurnRateCritical
      expr: |
        job:api_error_rate:ratio5m > (14.4 * 0.001)    # 14.4x burn rate
      for: 2m
      labels:
        severity: critical
        slo: api_availability
      annotations:
        summary: "API burning error budget 14x — will exhaust in < 5 days"

    # Slow burn: consuming budget at 2x normal rate
    - alert: ErrorBudgetBurnRateWarning
      expr: |
        job:api_error_rate:ratio5m > (3 * 0.001)       # 3x burn rate
      for: 1h
      labels:
        severity: warning
```

---

## Toil

Toil = manual, repetitive, automatable operational work that scales with service growth.

```
Examples of toil:
  - Manually restarting failed pods
  - Manually clearing disk space when alerts fire
  - Manually updating config files on servers
  - Copy-pasting queries to investigate incidents
  - Manually running database backups

SRE goal: Spend < 50% time on toil. Rest on engineering.

Eliminate toil by:
  - Automation (scripts, playbooks, runbooks)
  - Self-healing systems (Kubernetes auto-restarts)
  - Observability (alert before human notices)
  - Standardization (same setup across all services)
```

---

## Runbook Template

```markdown
# Alert: HighErrorRate — API Service

## Severity: Critical

## Impact
- User-visible: 5xx errors on all API endpoints
- Business: ~X% of checkout flows failing

## Automatic Actions
1. HPA scales up replicas (if CPU-related)
2. K8s restarts crashed pods

## Investigation Steps

### Step 1: Assess impact (2 min)
```bash
kubectl get pods -n production -l app=api
kubectl top pods -n production -l app=api
```

### Step 2: Check logs (3 min)
```bash
kubectl logs -l app=api -n production --tail=100 | grep -E "ERROR|FATAL|5[0-9]{2}"
```

### Step 3: Check dependencies
```bash
kubectl exec -it <api-pod> -n production -- curl -s http://postgres:5432
kubectl exec -it <api-pod> -n production -- redis-cli -h redis ping
```

## Resolution

**If database down**: See [postgres runbook](./postgres-runbook.md)
**If OOM**: `kubectl delete pod <pod>` to restart, then increase limits
**If deploy-related**: `kubectl rollout undo deployment/api -n production`
**If traffic spike**: `kubectl scale deployment api --replicas=20 -n production`

## Escalation
15 min: Page backend team lead
30 min: Page VP Engineering
```
