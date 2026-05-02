# SRE Incident Management

## Incident Lifecycle

```
Detection  →  Triage  →  Response  →  Resolution  →  Post-Mortem
(alert/user) (assess)    (fix)        (confirm)       (learn)

MTTD = Time to Detection
MTTA = Time to Acknowledge
MTTR = Time to Resolution
```

---

## Incident Severity Levels

| Sev | Impact | Response | Examples |
|-----|--------|---------|---------|
| SEV-1 | Complete outage / data loss | All hands, 5min ACK | Payment down, DB corruption |
| SEV-2 | Major feature broken, 50%+ users | On-call, 15min | Checkout slow 5x, auth errors |
| SEV-3 | Minor feature, degraded | Next business day | Search slow, PDF export broken |
| SEV-4 | Cosmetic, no user impact | Sprint backlog | Wrong text on error page |

---

## Incident Response Playbook

### Step 1: DETECT (< 2 min)
```
Alert fires → PagerDuty → On-call notified
OR
User reports → Support ticket → Ops channel

Action: Acknowledge within SLA
  SEV-1: 5 minutes
  SEV-2: 15 minutes
  SEV-3: 30 minutes
```

### Step 2: TRIAGE (< 5 min)
```
Answer these 3 questions:
1. What is broken? (symptom)
2. How many users? (blast radius)
3. How bad is it? (severity)

Open incident channel: #inc-YYYY-MM-DD-description
Announce: "Investigating reports of [X]. Blast radius: [Y]. Severity: [Z]"
```

### Step 3: COMMUNICATE (immediately)
```
Update status page (even if "we're investigating")
Notify VP Engineering if SEV-1
Notify affected teams
Post to #incidents: "SEV-1 incident: Payment service down. RCA in progress. ETA: unknown"
```

### Step 4: INVESTIGATE
```
Use the scientific method:
1. What is the symptom? (high error rate on /api/checkout)
2. When did it start? (check deployment history, git log)
3. What changed? (recent deploys, config changes, traffic)
4. Hypothesis: "Deploy at 14:00 introduced the bug"
5. Test: kubectl rollout undo deployment/checkout
6. Observe: did error rate drop?
```

### Step 5: MITIGATE (stop the bleeding)
```
Quick wins (seconds/minutes):
  - Rollback recent deployment
  - Scale up replicas (for overload)
  - Kill the bad pod (force restart)
  - Enable maintenance page
  - Circuit breaker (disable feature)

Full fix comes later — mitigate first!
```

### Step 6: RESOLVE
```
Criteria to close incident:
  - Error rate back to baseline
  - User reports confirmed resolved
  - SLO back in range
  - Status page updated: "Resolved at HH:MM"

Announce in incident channel: "✅ Incident resolved at HH:MM UTC. Duration: Xm. RCA to follow."
```

---

## Incident Commander Role

```
Large incidents need an Incident Commander (IC):
  - NOT fixing the problem (others do that)
  - Coordinating the response
  - Keeping communication flowing
  - Making decisions when team is stuck
  - Tracking timeline for post-mortem

IC checklist:
  [ ] Open incident channel
  [ ] Assign: IC (you), tech lead, comms lead
  [ ] Update status page every 15 min
  [ ] Take notes: what was tried, what worked
  [ ] Declare mitigation when users are unaffected
  [ ] Schedule post-mortem (within 48h)
  [ ] Close incident when resolved
```

---

## Runbook Template

```markdown
# Runbook: High Error Rate — API Service

## Alert
Name: SLOAvailabilityBudgetBurning
Threshold: Error rate > 1% for 5 min

## Severity
Critical (SEV-1 if > 10%, SEV-2 if 1-10%)

## Initial Assessment (2 min)
```bash
# 1. Check current error rate
curl "http://prometheus:9090/api/v1/query?query=job:http_error_rate:ratio5m"

# 2. Check pod health
kubectl get pods -n production -l app=api-service

# 3. Check recent deployments
kubectl rollout history deployment/api-service -n production | tail -5
```

## Investigation Steps

### Step 1: Check logs
```bash
kubectl logs -n production -l app=api-service --tail=100 | grep -E "ERROR|FATAL"
```

### Step 2: Check dependencies
```bash
# Is database reachable?
kubectl exec -it -n production $(kubectl get pod -n production -l app=api-service -o name | head -1) \
  -- curl -s postgres:5432 || echo "DB unreachable"
```

## Resolutions

| Root Cause | Fix | Time |
|-----------|-----|------|
| Bad deploy | `kubectl rollout undo deployment/api-service -n production` | 2 min |
| OOM | Delete crashing pod, increase limits | 5 min |
| DB overloaded | Scale down writes, add read replicas | 30 min |
| Memory leak | Rolling restart | 10 min |

## Escalation
15 min no progress → page backend team lead
30 min no progress → page VP Engineering
```

---

## Post-Mortem Structure

```markdown
# Post-Mortem: [Brief Title] — [Date]

## Incident Summary
- Duration: X minutes
- Impact: Y users affected, Z% requests failed
- SEV level: SEV-X

## Timeline (UTC)
| Time  | Event |
|-------|-------|
| 14:00 | Alert fired: error_rate > 5% |
| 14:02 | On-call acknowledged |
| 14:08 | Identified root cause: deploy at 13:58 |
| 14:12 | Rollback initiated |
| 14:15 | Error rate returned to normal |
| 14:17 | All-clear |

## Root Cause
[One clear sentence explaining what happened]

## Contributing Factors
1. No canary deployment → full rollout to production
2. Missing test for edge case in payment flow
3. Alert threshold too high (5% when 1% would catch earlier)

## Impact
- X requests failed
- Y users saw error page
- $Z estimated revenue impact

## What Went Well
- Fast detection (2 min from symptom to alert)
- Clear runbook helped
- Rollback was straightforward

## Action Items
| Action | Owner | Due | Priority |
|--------|-------|-----|---------|
| Add canary deployment to CD pipeline | @platform | Week 1 | P1 |
| Add test for payment edge case | @backend | Week 1 | P1 |
| Lower alert threshold to 1% | @sre | This week | P2 |

## Blameless Note
This post-mortem focuses on process improvements, not blame.
All team members acted in good faith with the information available.
```

---

## On-Call Best Practices

```
Before on-call week:
  □ Review recent incidents
  □ Read runbooks for common alerts
  □ Check escalation contacts are current
  □ Ensure laptop, VPN, phone are working

During on-call:
  □ Acknowledge within SLA
  □ Document everything in incident channel
  □ Escalate early — no heroes
  □ If paged > 3x in a night → escalate to reduce toil

After on-call week:
  □ Review: # of alerts, # of incidents, MTTD, MTTR
  □ File tickets for repeated toil
  □ Share learnings in team meeting
  □ Update runbooks for anything unclear
```
