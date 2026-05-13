# Incident Response Process — Quantum

## Severity Definitions

| Level | Response SLA | Example | Notification |
|---|---|---|---|
| P1 — Critical | < 5 min | Payment service down, 100% error rate | PagerDuty + Slack + SMS |
| P2 — High | < 30 min | High latency, elevated errors | PagerDuty + Slack |
| P3 — Medium | < 4 hours | Disk warning, non-critical degradation | Slack only |
| P4 — Low | Next business day | Cost anomaly, minor issue | Email digest |

---

## Incident Lifecycle

```
1. DETECTION      → Alert fires in Datadog → PagerDuty pages on-call
2. TRIAGE         → Acknowledge, open #inc- channel, assess severity
3. INVESTIGATION  → Use Datadog dashboards, APM, logs to find root cause
4. MITIGATION     → Apply fix, rollback, or scale
5. RESOLUTION     → Confirm recovery in Datadog, close PagerDuty
6. POST-MORTEM    → Timeline, RCA, action items (P1: 48h, P2: 1 week)
```

---

## On-Call Rotation

- **Rotation:** Weekly, handoff Sunday 00:00 UTC
- **Primary:** Receives all alerts
- **Secondary:** Backup and escalation
- **Schedule:** [PagerDuty link]

### Handoff Checklist

- [ ] Review open alerts and known issues
- [ ] Share any workarounds in effect
- [ ] Confirm PagerDuty schedule is correct
- [ ] Verify your phone number is current in PagerDuty
- [ ] Review upcoming deployments/changes for the week

---

## Escalation Policy

**P1 — Quantum Critical**
- 0 min: On-call engineer (SMS + push + call)
- 5 min: Backup on-call
- 10 min: Engineering manager
- 20 min: VP Engineering

**P2 — Quantum High**
- 0 min: On-call engineer (push + Slack)
- 30 min: Backup on-call
- 60 min: Engineering manager

---

## Key Datadog Links (bookmark these)

| Resource | URL |
|---|---|
| Infrastructure Map | https://app.datadoghq.com/infrastructure/map |
| APM Services | https://app.datadoghq.com/apm/services |
| Log Explorer | https://app.datadoghq.com/logs |
| Active Monitors | https://app.datadoghq.com/monitors/manage |
| Incidents | https://app.datadoghq.com/incidents |
| Datadog Status | https://status.datadoghq.com |
