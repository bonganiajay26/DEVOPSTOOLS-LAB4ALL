# SRE Interview Questions

## Q1. Explain SLI, SLO, and SLA with concrete examples.

**SLI** (what we measure):
- `successful_requests / total_requests` = availability indicator
- `requests_under_500ms / total_requests` = latency indicator

**SLO** (our internal target):
- Availability SLO: 99.9% (must measure as rolling 30-day window)
- Latency SLO: 95% of requests complete in < 500ms

**SLA** (contractual promise to customer):
- "99% uptime guarantee. If violated, 10% service credit."
- Always weaker than SLO (buffer for real incidents)

**Error budget** from the SLO:
- Monthly budget = (1-0.999) × 43,200 min = 43.2 min downtime/month

---

## Q2. Your error budget is at 10% with 2 weeks left in the month. What do you do?

```
Immediate actions:
1. Stop non-critical feature deployments
2. Cancel any planned risky changes (schema migrations, infra upgrades)
3. Review recent incidents — fix root causes
4. Increase monitoring coverage on flaky components

Engineering work:
5. Identify top error budget consumers (which incidents cost most)
6. Fix top 3 reliability issues
7. Add circuit breakers for dependency failures
8. Implement graceful degradation

Communicate:
9. Notify product team: "No new features until reliability improves"
10. Track error budget as team-level KPI

Next month prevention:
11. Add pre-deployment reliability checklist
12. Add canary deployments to catch bad releases early
```

---

## Q3. How do you write a good post-mortem?

```markdown
# Incident: API Outage (30 min) — 2024-01-15

## Summary
30 minutes of elevated error rate (40%) due to database connection pool exhaustion
triggered by a memory leak in the auth service.

## Impact
- 40% of API requests failed (status 503)
- Estimated 5,000 users affected
- Revenue impact: ~$12,000

## Timeline (UTC)
14:32 — Alert fires: error_rate > 5%
14:34 — On-call engineer paged
14:38 — Identified pod CPU spiking, not DB
14:45 — Found memory leak in auth service logs
14:48 — Rolled back auth service to v1.2.1
15:00 — Error rate returned to normal
15:02 — All-clear

## Root Cause
Auth service v1.2.2 introduced a connection pool leak (PR #456).
Connections were not released after JWT validation, exhausting the
PostgreSQL connection limit (100) within 25 minutes.

## Contributing Factors
- No memory leak test in test suite
- Connection pool size alert threshold was set too high (90% instead of 70%)
- Canary deployment missed this — canary traffic was too low to trigger

## Action Items
| Action | Owner | Due |
|--------|-------|-----|
| Add connection pool test to CI | @backend-team | 2024-01-22 |
| Reduce alert threshold to 70% | @platform-team | 2024-01-17 |
| Increase canary traffic % to 20% | @platform-team | 2024-01-17 |
| Add connection count metric | @backend-team | 2024-01-22 |

## What Went Well
- Detection was fast (2 minutes from spike to alert)
- Rollback was straightforward (5 minutes)
- Runbook was accurate and helpful

## Blameless Note
This incident was caused by a process gap (no pool leak tests),
not individual failure. Actions focus on process improvement.
```

---

## Q4. What is toil and how do you measure it?

Toil is manual, repetitive, operational work that:
- Has no lasting value (doesn't improve the system)
- Scales linearly with service growth
- Could be automated

```python
# Measure toil:
# Track time spent on categories for 2 weeks:

toil_categories = {
    "restarting_services": "2h/week",     # Automatable with health checks
    "disk_space_cleanup": "1h/week",      # Automate with lifecycle policies
    "manual_deployments": "3h/week",      # Automate with CI/CD
    "responding_to_noisy_alerts": "4h/week",  # Fix alert quality
    "on_call_interruptions": "5h/week",   # Fix root causes
}

total_toil = sum → 15h/week
engineering_time = 40h/week
toil_percentage = 15/40 = 37.5%  # SRE goal: < 50%

# Action: Automate top toil sources first (highest ROI)
```

---

## Q5. How do you implement chaos engineering?

```bash
# Principles: controlled experiments, small blast radius, learn from failure

# Tool: Chaos Monkey / Chaos Toolkit / LitmusChaos

# LitmusChaos experiment: kill random pod in production during business hours
kubectl apply -f - << 'EOF'
apiVersion: litmuschaos.io/v1alpha1
kind: ChaosEngine
metadata:
  name: pod-delete-chaos
  namespace: production
spec:
  appinfo:
    appns: production
    applabel: app=api-service
  chaosServiceAccount: litmus-sa
  experiments:
  - name: pod-delete
    spec:
      components:
        env:
        - name: TOTAL_CHAOS_DURATION
          value: "30"          # 30 seconds of chaos
        - name: CHAOS_INTERVAL
          value: "10"          # Kill pod every 10 seconds
        - name: FORCE
          value: "false"       # Graceful kill
EOF

# After experiment: check SLO was maintained
# Prometheus: was error_rate > 0 during chaos window?

# Hypothesis → Experiment → Observe → Learn → Automate

# What to test:
# - Pod deletion (K8s self-healing)
# - Node failure (rescheduling)
# - Network latency injection (timeout handling)
# - Database failure (circuit breaker activation)
# - CPU stress (HPA behavior)
```

---

## Q6. What is the difference between MTTR, MTBF, and MTTD?

```
MTTD (Mean Time To Detect)
  → How long until we know there's a problem?
  → Improve: better monitoring, alerting, tracing

MTTA (Mean Time To Acknowledge)
  → How long until someone starts working on it?
  → Improve: better on-call coverage, alert routing, runbooks

MTTR (Mean Time To Restore/Recover)
  → How long until service is restored?
  → Improve: feature flags, blue/green deploys, rollback automation, runbooks

MTBF (Mean Time Between Failures)
  → How often do incidents occur?
  → Improve: testing, code quality, infrastructure reliability, chaos engineering

Availability = MTBF / (MTBF + MTTR)
Goal: Maximize MTBF, minimize MTTR
```

---

## Q7. How do you handle an on-call rotation fairly?

```
Structure:
- Primary + Secondary on-call (primary pages first, secondary if no ACK in 5m)
- Weekly rotation (not monthly — prevents knowledge hoarding)
- Follow-the-sun for global teams (handoff to next timezone)
- On-call free time: if paged 3+ times/night, next day is recovery day

Alert quality:
- Review alert noise monthly
- Every alert must be actionable (if you can't act on it, delete it)
- Every alert must have a runbook
- Target: < 2 actionable pages/shift

Compensation:
- On-call compensation for engineers (financial or comp time)
- No feature deadlines during on-call week

Onboarding:
- Shadow before primary
- Runbook library, architecture diagrams, escalation paths
- Gameday: practice incident response before real incidents
```

---

## Q8. What is an error budget burn rate alert?

```promql
# Multi-window, multi-burn-rate alerts (Google SRE Workbook)
# Alert when consuming budget faster than sustainable

# Fast burn: consuming 2% budget in 1h (will exhaust 30d budget in 2 days)
# 2% in 1h = burning at 14.4x normal rate
# 14.4 = 2% / (1h/720h) = 2% / 0.139%

expr: (
  rate(http_requests_total{status=~"5.."}[1h])
  /
  rate(http_requests_total[1h])
) > (14.4 * 0.001)   # SLO = 99.9%, 1-SLO = 0.001

# Slow burn: consuming 5% budget in 6h
# 5% in 6h = burning at 6x normal rate
expr: (
  rate(http_requests_total{status=~"5.."}[6h])
  /
  rate(http_requests_total[6h])
) > (6 * 0.001)

# Why multi-window:
# Fast burn = immediate page (critical)
# Slow burn = ticket (investigate in business hours)
```

---

## Q9. Describe the ideal on-call handoff process.

```markdown
# Daily Handoff Template

## Active Incidents
- [ ] None

## Ongoing Issues (not incidents, but watch)
- DB replica lag is elevated (15s, threshold 30s) — watching
- Node node-3 has disk at 78% — ticket #1234 to clean up

## Recent Changes (last 24h that might cause issues)
- Deployed api-service v2.4.1 at 14:00 UTC
- Increased DB connection pool to 200

## Error Budget Status
- API availability: 99.95% (30-day) — healthy, budget at 85%
- Latency p99: 320ms — within SLO

## Known Noisy Alerts (can silence/ignore)
- DiskSpaceWarning on backup-01 — planned cleanup in 2h

## Escalation Contacts
- Database issues: @db-team
- Infrastructure: @platform-team
- Business critical: VP Engineering
```

---

## Q10. How do you reduce MTTR?

```
1. Runbooks (most impactful)
   - Every alert has a runbook
   - Updated after every incident
   - Includes copy-paste commands, not vague instructions

2. Automated remediation
   - Auto-scaling for traffic spikes
   - Auto-restart for crashed pods (K8s)
   - Circuit breakers for cascading failures

3. Feature flags
   - Kill switches for problematic features (no deploy needed)
   - "Turn off payments v2, fallback to v1" = 30 seconds

4. Automated rollback
   - Canary analysis → auto-rollback on SLO violation
   - GitHub Actions: rollback on smoke test failure

5. Observability
   - Clear dashboards → faster diagnosis
   - Distributed tracing → find bottleneck in seconds
   - Correlated logs+metrics+traces

6. Regular gamedays
   - Practice incident response quarterly
   - Test runbook accuracy
   - Identify missing documentation
```

---

## Q11. What are the four golden signals?

Google's four metrics that matter most for any service:

```
1. Latency
   "How long does it take to service a request?"
   Key: Distinguish successful vs failed request latency
   Metric: histogram_quantile(0.99, rate(request_duration_bucket[5m]))

2. Traffic
   "How much demand is on the system?"
   Metric: rate(http_requests_total[5m])

3. Errors
   "What rate of requests are failing?"
   Key: Distinguish different error types (user error vs system error)
   Metric: rate(http_requests_total{status=~"5.."}[5m])

4. Saturation
   "How full is the service?"
   Metric: CPU%, memory%, queue depth, connection pool usage
   Predict: use predict_linear() for disk saturation
```

---

## Q12. How do you calculate error budget remaining?

```python
# Monthly error budget for 99.9% SLO
slo_target = 0.999
total_minutes_in_month = 30 * 24 * 60  # 43,200 minutes
allowed_downtime_minutes = (1 - slo_target) * total_minutes_in_month
# = 0.001 × 43,200 = 43.2 minutes

# Actual downtime this month (from incident log)
actual_downtime_minutes = 12  # 12 minutes of incidents

# Remaining budget
budget_remaining = allowed_downtime_minutes - actual_downtime_minutes
# = 43.2 - 12 = 31.2 minutes remaining

# Budget percentage remaining
budget_remaining_pct = budget_remaining / allowed_downtime_minutes * 100
# = 31.2 / 43.2 * 100 = 72.2% remaining

# PromQL equivalent
(
  1 - (
    sum(rate(http_requests_total{status=~"5.."}[30d]))
    /
    sum(rate(http_requests_total[30d]))
  )
) / 0.001 * 100   # = % of error budget remaining
```

---

## Q13. What is capacity planning in SRE?

```
Capacity planning = ensuring service can handle expected (and unexpected) load

Steps:
1. Measure current utilization (CPU, memory, requests/s)
2. Identify bottlenecks (what breaks first under load)
3. Load test to find breaking point
4. Forecast growth (traffic × growth rate × safety margin)
5. Plan infrastructure before you need it (lead time!)

Formula:
required_capacity = (current_load × growth_rate_90d × safety_factor)
safety_factor = 1.5   # 50% headroom for spikes

Example:
Current: 1000 req/s, 60% CPU utilization
Growth: 20% per month
90 days: 1000 × 1.2^3 = 1728 req/s
With safety: 1728 × 1.5 = 2592 req/s needed
Current max: 1000 / 0.6 = 1667 req/s
Action: Add capacity before 90 days elapsed!
```

---

## Q14. Explain the difference between a severity 1 and severity 2 incident.

```
Severity 1 (Critical — all hands now):
- Complete service outage or > 50% users affected
- Data loss or corruption
- Security breach
- SLO breach (error budget exhausted)
- Revenue-generating features down
→ Page all available engineers, 5-minute ACK SLA, executive notification

Severity 2 (High — immediate but not all hands):
- Significant degradation (< 50% users affected)
- Major feature unavailable
- Performance severely degraded
- Approaching SLO breach
→ On-call responds within 15 minutes, work during business hours OK if stable

Severity 3 (Medium):
- Minor feature unavailable
- Performance degraded but within SLO
→ Create ticket, address next sprint

Severity 4 (Low):
- Cosmetic issues, very minor impact
→ Backlog, address when convenient
```

---

## Q15. How do you build a culture of blameless post-mortems?

```
Principles:
1. Assume everyone did their best given what they knew
2. Failures are system problems, not people problems
3. Focus on "what" and "why", not "who"
4. Learning over punishment

Facilitation techniques:
- Use "the system" not people names when describing root cause
  "The alert threshold was set too high" not "John set it wrong"
- "Five whys" to find systemic issues
- Action items are process/tool improvements, not "be more careful"
- Share post-mortems publicly (internal wiki) — everyone learns

Bad post-mortem: "Dev pushed broken code without testing"
Good post-mortem: "No automated test covered this code path.
                   Action: Add integration test for payment validation."

Signs of healthy culture:
- Engineers report near-misses voluntarily
- Post-mortems focus on action items
- Same failure doesn't happen twice
- On-call rotation is not dreaded
```
