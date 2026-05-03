# Post-Mortem: [TITLE]

**Date**: YYYY-MM-DD  
**Severity**: SEV1 / SEV2 / SEV3  
**Status**: Draft | In Review | Final  
**Authors**: @ic-name, @tech-lead-name  

> *Blameless. We assume everyone acted in good faith with the information available.*

---

## Summary

*2–3 sentences. What happened, who was affected, how long it lasted.*

On [DATE], [SERVICE] experienced [SYMPTOM] for approximately [DURATION].
[X]% of users attempting to [ACTION] were affected.
The incident was caused by [ONE SENTENCE ROOT CAUSE].

---

## Impact

| Metric | Value |
|--------|-------|
| Start time | HH:MM UTC |
| Resolved time | HH:MM UTC |
| Duration | X minutes |
| Users affected | ~X (Y% of total) |
| Revenue impact | $X estimated |
| Regions affected | us-east-1 / all |
| SLA breached | Yes / No |
| Error budget consumed | X min (Y% of monthly budget) |

---

## Timeline (UTC)

| Time | Event |
|------|-------|
| HH:MM | Symptom begins (based on Prometheus timeline) |
| HH:MM | SLO burn-rate alert fires |
| HH:MM | On-call acknowledges (MTTA: X min) |
| HH:MM | Incident declared. IC: @name. Channel: #inc-... |
| HH:MM | Status page updated: Investigating |
| HH:MM | Blast radius assessed: [brief] |
| HH:MM | Hypothesis 1: [what] — RULED OUT because [evidence] |
| HH:MM | Hypothesis 2: [what] — CONFIRMED by [evidence] |
| HH:MM | Mitigation applied: [rollback / scale / feature flag / other] |
| HH:MM | Error rate returned to baseline |
| HH:MM | All-clear declared. Status page: Resolved |
| +24h | Post-mortem draft circulated |
| +48h | Post-mortem meeting held |

---

## Root Cause

*One clear sentence. System-level, not person-level.*

> Example: "Deployment v2.3.1 introduced a database query missing an index, causing
> full table scans that saturated the DB connection pool at production load (not
> reproducible in staging due to 50x smaller dataset)."

**FILL IN**

---

## Contributing Factors

*Why was this failure mode possible? Focus on systems and processes.*

1. **[Factor]** — [Why it contributed]
2. **[Factor]** — [Why it contributed]
3. **[Factor]** — [Why it contributed]

*Examples:*
*- "No slow-query alert on RDS instance"*
*- "Staging dataset 50x smaller than production"*
*- "No canary deployment — change went to 100% of pods immediately"*
*- "Code review checklist didn't include performance regression check"*

---

## What Went Well

*Genuinely recognize things that worked. This is not a formality.*

1. **Detection was fast** — Alert fired within 90 seconds of symptom
2. **On-call acknowledged** within 2 minutes
3. **Rollback was straightforward** — under 3 minutes start to finish
4. **Communication was clear** — status page updated within 5 minutes

---

## What Could Be Improved

*Process and system improvements. Not "be more careful."*

1. **[Improvement]** — [Why it would help]
2. **[Improvement]** — [Why it would help]
3. **[Improvement]** — [Why it would help]

---

## Action Items

*Every item needs: specific action, single owner, deadline, priority.*

| # | Action | Owner | Due | Priority | Status |
|---|--------|-------|-----|----------|--------|
| 1 | Add slow query alert (> 5s) to RDS monitoring | @alice | Jan 20 | P1 | Open |
| 2 | Fix missing index on `user_sessions.created_at` | @backend | Jan 17 | P1 | Done |
| 3 | Create DB migration review checklist | @dba + @backend-lead | Jan 29 | P2 | Open |
| 4 | Add production-scale perf test to CI pipeline | @platform | Feb 5 | P2 | Open |
| 5 | Add canary deployment to all critical services | @sre | Feb 12 | P3 | Open |

**P1** = This sprint | **P2** = Next sprint | **P3** = Backlog (tracked)

---

## Detection & Response Metrics

| Phase | Duration | Target |
|-------|----------|--------|
| MTTD (symptom → alert) | X min | < 2 min |
| MTTA (alert → ACK) | X min | < 5 min |
| MTTI (ACK → investigating) | X min | < 2 min |
| MTTM (declared → mitigated) | X min | < 15 min |
| MTTR (declared → resolved) | X min | < 20 min |

---

## Appendix

### Prometheus Queries Used

```promql
# Error rate during incident
sum(rate(http_requests_total{status=~"5.."}[5m])) by (job)

# SLO burn rate
sum(rate(http_requests_total{status=~"5.."}[5m]))
  / sum(rate(http_requests_total[5m]))
  / 0.001

# DB connection pool
pg_stat_activity_count / pg_settings_max_connections * 100
```

### Key Commands Run

```bash
# Commands that helped diagnose this incident:
kubectl describe pod [pod-name] -n production
kubectl logs [pod-name] -n production --previous
kubectl exec -it [pod-name] -- psql -U postgres -c "SELECT count(*) FROM pg_stat_activity"
kubectl rollout undo deployment/payment-api -n production
```

---

*Post-mortem generated: [DATE]*  
*Meeting scheduled: [DATE+TIME] — Attendees: IC, Tech Lead, Team Lead*  
*Published: [DATE]*
