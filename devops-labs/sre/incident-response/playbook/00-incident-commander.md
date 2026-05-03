# Incident Commander (IC) Guide

## The Most Important Rule

> **The IC does NOT fix the problem.**
> The IC coordinates the people who fix the problem.

If you are debugging, you are not commanding.
If you are commanding, you are not debugging.
These are two different jobs. Assign them to two different people.

---

## IC Responsibilities

```
DURING INCIDENT:
  ✅ Assign roles (tech lead, comms lead, scribe)
  ✅ Keep everyone focused on current hypothesis
  ✅ Call the pivot ("That's 10 min on that hypothesis, move on")
  ✅ Update Slack channel every 15 minutes
  ✅ Make the "restore vs diagnose" call
  ✅ Decide when to escalate (VP, Legal, Customer Success)
  ✅ Declare all-clear when service is restored

NOT IC's job:
  ❌ Running kubectl commands
  ❌ Reading log files
  ❌ Debugging application code
  ❌ Writing the fix
```

---

## Role Assignments (first 2 minutes)

```
Incident Commander (IC):
  → Coordinates response, owns communication
  → Usually: senior SRE or on-call lead

Technical Lead:
  → Owns the investigation and fix
  → Usually: engineer most familiar with affected service

Communications Lead:
  → Owns external communication (status page, customer email)
  → Usually: developer relations, support lead, or PM

Scribe:
  → Documents timeline in real-time in the incident channel
  → Usually: second engineer on rotation

Subject Matter Experts (as needed):
  → Database specialist, network engineer, security, etc.
  → Pulled in when hypothesis requires their domain
```

---

## IC Checklist

### 0–5 minutes
```
□ Acknowledge alert in PagerDuty/Opsgenie
□ Join or create #inc-YYYY-MM-DD-description channel
□ Assign IC, Tech Lead, Comms Lead, Scribe
□ Post initial Slack message (see templates/incident-declaration.md)
□ Update status page: "We are investigating reports of [X]"
□ Set a 5-minute timer for first status update
□ Start incident log: "14:32 UTC - Alert fired. IC: [name]. TL: [name]."
```

### 5–15 minutes
```
□ Ensure blast radius is known: how many users? which regions?
□ Ask Tech Lead: "What is your current hypothesis?"
□ Ask: "Can we mitigate before we diagnose?" (rollback? failover?)
□ Post update to Slack every 10 minutes minimum
□ Update status page every 15 minutes
□ Set hypothesis timer: if no confirmation in 10 min → call pivot
```

### Mitigation phase
```
□ When Tech Lead proposes a fix: "What is the risk of this change?"
□ If risk is low → approve immediately
□ If risk is high → ask "what is the risk of NOT doing it?"
□ After mitigation: monitor for 5 min before declaring success
□ Post: "We believe we have mitigated the issue. Monitoring."
```

### Resolution
```
□ Confirm error rate returned to baseline
□ Confirm SLO burn rate is below threshold
□ Update status page: "Resolved at HH:MM UTC"
□ Post all-clear in Slack with summary
□ Schedule post-mortem within 48 hours
□ Send customer notification if SLA was breached
□ Page down / de-escalate PagerDuty
```

---

## The 10-Minute Pivot Rule

```
IF a hypothesis has been pursued for 10 minutes
AND there is no confirming evidence
THEN: the IC calls the pivot.

Script:
  "We've been on [database hypothesis] for 10 minutes without
   confirmation. Let's move to [next hypothesis]. [Name],
   what's your next theory?"

Why this works:
  Engineers get tunnel vision. They find something "suspicious"
  and spend 45 minutes proving their original hunch wrong.
  The IC has no emotional attachment to the hypothesis.
```

---

## Escalation Decision Tree

```
IS THE INCIDENT:                              → ACTION
───────────────────────────────────────────────────────
SEV1, not mitigated after 30 min?            → Page VP Eng
Revenue system down > 15 min?                → Page VP + CEO
Data breach possible?                        → Page Security + Legal
SLA breach (> agreed downtime)?             → Page Customer Success
External dependency (AWS/GCP down)?         → Post on status page, no ETA

ESCALATION CONTACTS (fill in for your org):
  Engineering VP:     [phone / PagerDuty]
  On-call DBA:        [phone / PagerDuty]
  On-call Security:   [phone / PagerDuty]
  Customer Success:   [Slack handle]
  Legal:              [phone / email]
```

---

## Communication Cadence

```
TIME          ACTION
─────────────────────────────────────────────────────────
T+0 min       Status page: "Investigating reports of [X]"
T+5 min       Slack update: "IC assigned. Investigating..."
T+15 min      Status page + Slack: "We have identified [X]..."
T+30 min      Slack: "Update: still investigating. Current focus: [Y]"
Every 15 min  Slack update (even if "no new updates — still monitoring")
Mitigation    Status page: "We believe we have resolved [X]. Monitoring."
Resolved      Status page: "Resolved at [time]. See post-mortem for details."
48 hours      Post-mortem published internally
72 hours      Customer summary sent (if SEV1)
```

---

## What Good Looks Like vs What Bad Looks Like

| Situation | Bad IC | Good IC |
|-----------|--------|---------|
| Everyone silent | "Any updates?" (10 min later) | "Name, what's your current theory? What have you ruled out?" |
| Wrong hypothesis | Lets team dig for 30 min | Calls pivot at 10 min |
| Conflicting theories | Both teams dig in parallel | "Test hypothesis A first. If no result in 10 min, we try B" |
| Fix requires downtime | Waits for perfect solution | "Acceptable tradeoff. Do it." |
| Alert resolved itself | "Looks like it fixed itself" | "Hold — let's confirm root cause before closing" |
| Post-mortem | "Let's do one sometime" | Booked within 48h, attendees notified |
