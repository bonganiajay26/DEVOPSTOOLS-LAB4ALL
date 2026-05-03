# Phase 1 — Detect & Declare (0–5 minutes)

## Goal
Acknowledge the alert, assemble the response team, open the communication
channels, and post the first status update — all within 5 minutes.

---

## Detection: SLO Burn-Rate Alerting

The fastest detection is not human — it is automated SLO burn-rate alerting.

```
Traditional threshold alert:
  "error rate > 1%" → fires after sustained breach
  Problem: fires too late, too noisy, no context on business impact

SLO burn-rate alert:
  "consuming error budget 14x faster than normal"
  = will exhaust monthly budget in < 2 days at this rate
  Result: fires early, fires with context, minimal false positives
```

### Multi-window burn-rate rules (Google SRE Workbook algorithm)

```promql
# CRITICAL: Fast burn — 2% of monthly budget consumed in 1 hour
# Burn rate = 14.4x normal → will exhaust budget in ~2 days
(
  sum(rate(http_requests_total{status=~"5.."}[5m]))
  /
  sum(rate(http_requests_total[5m]))
) > (14.4 * 0.001)   # SLO target = 99.9%, error budget = 0.001

# WARNING: Slow burn — 5% of monthly budget consumed in 6 hours
# Burn rate = 6x normal
(
  sum(rate(http_requests_total{status=~"5.."}[6h]))
  /
  sum(rate(http_requests_total[6h]))
) > (6 * 0.001)
```

See `prometheus/slo-burn-rate-alerts.yaml` for full PrometheusRule.

---

## Alert → Human Pipeline

```
Prometheus alert fires
      │
      ▼
Alertmanager routes by severity:
  critical → PagerDuty (pages on-call engineer)
  warning  → Slack #alerts-warning (no page)
      │
      ▼
PagerDuty notifies on-call engineer:
  1st page: push notification + call
  No ACK in 5 min: escalation to secondary
  No ACK in 15 min: page engineering manager
      │
      ▼
Engineer acknowledges → assumes IC role
```

---

## Step-by-Step: First 5 Minutes

### T+0 — Alert fires
```bash
# On-call engineer receives PagerDuty notification
# ACKNOWLEDGE IMMEDIATELY — stops escalation timer

# From phone: swipe to acknowledge in PagerDuty app
# From web:   click Acknowledge in PagerDuty

# Assess severity from alert title:
# SEV1: complete outage, revenue impact, data breach
# SEV2: major feature down, 20%+ users affected
# SEV3: minor degradation, < 5% affected
```

### T+1 — Declare the incident
```bash
# Run the declaration script (auto-creates Slack channel)
bash scripts/01-declare-incident.sh \
  --severity SEV1 \
  --title "Payment service returning 500s" \
  --service payment-api \
  --ic "your-name"

# This script:
# 1. Creates #inc-YYYY-MM-DD-payment-500s channel
# 2. Posts initial message with severity template
# 3. Pings @oncall-payments and @sre-team
# 4. Creates PagerDuty incident (if not already)
# 5. Posts a reminder to update status page
```

### T+2 — Assign roles (post in incident channel)
```
@channel — Incident declared. Roles:
  IC:     @your-name
  TL:     @tech-lead-name
  Comms:  @comms-lead-name
  Scribe: @scribe-name

Current info:
  Alert: Payment service error rate > 15% (SLO burn 150x)
  Severity: SEV1
  Started: ~14:32 UTC (based on alert)
  Status page: PENDING UPDATE
```

### T+3 — Update status page
```
INVESTIGATING (post immediately — even before you know anything)

Title:  "Payment Service Degradation"
Status: Investigating
Body:   "We are investigating reports of errors when processing
         payments. Our team is engaged. We will update every
         15 minutes. [14:33 UTC]"

KEY RULE: Never say "resolved" before it is actually resolved.
          Never give an ETA you are not certain about.
```

### T+5 — First Slack update
```
[14:37 UTC] STATUS UPDATE #1
  IC: @your-name
  Status: INVESTIGATING
  Blast radius: TBD (measuring now)
  Current hypothesis: None confirmed yet
  Next update: 14:52 UTC (15 min)
  Status page: Updated ✅
```

---

## Severity Classification

```
SEV1 — Critical (all hands, page leadership)
  □ Complete service outage
  □ Revenue-generating feature down
  □ Data loss or data breach
  □ SLA will be breached
  □ > 50% of users affected
  Response: 5-min ACK, IC + TL + Comms

SEV2 — High (on-call responds, monitor closely)
  □ Major feature unavailable
  □ 20–50% of users affected
  □ Performance degraded > 3x
  □ Error budget burning fast (but not exhausted)
  Response: 15-min ACK, on-call + 1 backup

SEV3 — Medium (investigate during business hours)
  □ Minor feature unavailable
  □ < 20% of users affected
  □ Performance degraded < 3x
  □ Error budget affected but not critical
  Response: Create ticket, address next sprint

SEV4 — Low (cosmetic, no user impact)
  □ UI display issue
  □ Non-critical alert
  □ Documentation error
  Response: Backlog
```
