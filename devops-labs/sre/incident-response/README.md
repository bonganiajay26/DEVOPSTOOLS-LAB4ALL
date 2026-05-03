# Production Incident Response Playbook

> **How MTTR was reduced from 4 hours → under 20 minutes at VersatileCommerce.**
> Built on: automated SLO burn-rate detection, pre-written runbooks for the top 10
> incident patterns, and quarterly drills. Every file in this repo is production-ready.

---

## The Core Principle

```
REACTIVE (before):               STRUCTURED (after):
  Alert fires                      Alert fires
  → Panic                          → Phase 1: Declare  (0–5 min)
  → Everyone digs at once          → Phase 2: Triage   (5–15 min)
  → Conflicting hypotheses         → Phase 3: Diagnose (structured)
  → Rabbit holes                   → Phase 4: Mitigate (restore first)
  → Fix eventually                 → Phase 5: Resolve  (RCA + postmortem)
  MTTR: 4 hours                    MTTR: <20 minutes
```

---

## The 5-Phase Playbook

```
Phase 1 ─ DETECT & DECLARE    (0–5 min)
  SLO burn-rate alert fires → PagerDuty → Incident Commander assumed
  Slack channel created → Status page updated → blast radius estimated

Phase 2 ─ TRIAGE              (5–15 min)
  How many users? Getting worse or stable?
  Can we mitigate without full diagnosis? (failover, rollback, feature flag)

Phase 3 ─ DIAGNOSE            (15–25 min)
  Symptom → trace backward through the call chain
  Rule: if hypothesis not confirmed in 10 min → PIVOT
  Use distributed tracing (Jaeger/Dynatrace) not just logs

Phase 4 ─ MITIGATE            (as fast as possible)
  Restore service FIRST. Root cause can wait.
  Safe default: revert last deployment.

Phase 5 ─ RESOLVE & DOCUMENT  (post-incident)
  Service stable → root cause analysis
  Blameless post-mortem within 48 hours
  Action items with owners + deadlines
```

---

## Folder Structure

```
incident-response/
├── README.md                          ← This file
├── playbook/
│   ├── 00-incident-commander.md      ← IC role, responsibilities, checklist
│   ├── 01-detect-declare.md          ← Phase 1: 0–5 min
│   ├── 02-triage.md                  ← Phase 2: blast radius assessment
│   ├── 03-diagnose.md                ← Phase 3: hypothesis testing methodology
│   ├── 04-mitigate.md                ← Phase 4: restore-first tactics
│   └── 05-resolve-document.md        ← Phase 5: RCA + post-mortem
├── runbooks/
│   ├── 01-high-error-rate.md         ← Top 10 incident patterns
│   ├── 02-high-latency.md
│   ├── 03-pod-crashloop.md
│   ├── 04-database-down.md
│   ├── 05-deployment-rollback.md
│   ├── 06-disk-pressure.md
│   ├── 07-memory-pressure.md
│   ├── 08-certificate-expired.md
│   ├── 09-external-dependency-down.md
│   └── 10-dns-failure.md
├── scripts/
│   ├── 01-declare-incident.sh        ← Auto: Slack channel + PD ack + status
│   ├── 02-blast-radius.sh            ← Measure scope of impact
│   ├── 03-diagnose.sh                ← Systematic triage commands
│   ├── 04-safe-rollback.sh           ← One-command deployment rollback
│   └── 05-post-mortem-generator.py  ← Auto-populate post-mortem template
├── prometheus/
│   └── slo-burn-rate-alerts.yaml     ← Multi-window SLO alerting
├── templates/
│   ├── incident-declaration.md       ← Slack message template
│   ├── status-page-updates.md        ← Customer-facing communication
│   └── post-mortem.md                ← Blameless post-mortem template
├── drills/
│   ├── quarterly-drill-guide.md      ← How to run GameDay exercises
│   └── scenarios/
│       ├── scenario-01-db-failure.md
│       ├── scenario-02-traffic-spike.md
│       └── scenario-03-bad-deploy.md
└── automation/
    ├── pagerduty-webhook.py          ← Auto-create Slack channel on alert
    └── slack-bot-commands.md         ← /incident commands
```

---

## The Numbers

| Metric | Before | After | How |
|--------|--------|-------|-----|
| MTTD (detection) | 8 min | 45 sec | SLO burn-rate alerts |
| MTTA (acknowledge) | 12 min | 2 min | PagerDuty mobile + escalation |
| MTTR (resolution) | 4 hours | 18 min | Runbooks + rollback automation |
| Post-mortems written | ~30% | 100% | Mandatory + template |
| Repeat incidents | 40% | 8% | Action items tracked to completion |

---

## Quick Reference — First 5 Minutes

```bash
# 1. Acknowledge the alert (stop the paging)
#    PagerDuty mobile app → Acknowledge

# 2. Declare the incident + create response channel
bash scripts/01-declare-incident.sh \
  --severity SEV1 \
  --title "API error rate 15%" \
  --service api-gateway

# 3. Measure blast radius
bash scripts/02-blast-radius.sh --namespace production

# 4. Post initial update to status page
# → See templates/status-page-updates.md

# 5. Start diagnosis timer (if not solved in 10 min → pivot hypothesis)
echo "Diagnosis started: $(date)"
```
