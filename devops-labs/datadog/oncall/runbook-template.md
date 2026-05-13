# Runbook: [Alert Name]

**Service:** my-service  
**Severity:** P1 / P2 / P3  
**Owner:** [Team Name]  
**PagerDuty Policy:** quantum-critical  
**Last Updated:** YYYY-MM-DD  

---

## What is this alert?

Brief plain-English description of what triggered and why it matters.

## Customer Impact

- Who is affected and how
- Estimated blast radius

## Immediate Actions (first 5 minutes)

1. Acknowledge in PagerDuty
2. Open `#inc-YYYYMMDD-brief-description` Slack channel
3. Check service dashboard: [link]
4. Check recent deployments: [link]

## Diagnostic Steps

```bash
# Check pod status
kubectl get pods -n <namespace> -l app=<service>

# Check logs for errors (last 100 lines)
kubectl logs -n <namespace> -l app=<service> --tail=100 | grep ERROR

# Check DB connectivity
kubectl exec -n <namespace> deploy/<service> -- pg_isready -h db.internal

# Check downstream dependencies
curl -s http://<service>/health | jq .
```

## Common Causes and Fixes

| Symptom | Likely Cause | Fix |
|---|---|---|
| All pods CrashLoopBackOff | Bad deployment | `kubectl rollout undo deploy/<service>` |
| DB connection errors | DB overloaded | Scale connection pool, check DB dashboard |
| High error rate post-deploy | Bug in new code | `helm rollback <service>` |
| Memory pressure | Leak or traffic spike | Scale replicas or restart pods |

## Escalation

- Not resolved in **15 min**: page engineering manager
- Database issue: page `@db-oncall`
- Network/infra issue: page `@infra-oncall`

## Post-Incident

- [ ] Incident closed in PagerDuty
- [ ] Status page updated
- [ ] Post-mortem scheduled (P1 within 48h, P2 within 1 week)

## Related Links

- [Service Dashboard](https://app.datadoghq.com/dashboard)
- [Log Explorer](https://app.datadoghq.com/logs)
- [Previous Incidents](https://app.datadoghq.com/incidents)
- [Deployment History](https://github.com/quantum/<service>/deployments)
