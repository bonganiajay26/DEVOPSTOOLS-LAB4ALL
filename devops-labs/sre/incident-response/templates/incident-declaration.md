# Incident Declaration Templates

Copy the appropriate template into your incident Slack channel.

---

## SEV1 — Critical

```
🔴 *SEV1 INCIDENT DECLARED*
━━━━━━━━━━━━━━━━━━━━━━━━━━
*Issue:*      [Brief description — e.g., Payment API returning 503s]
*Service:*    [Affected service name]
*Started:*    [HH:MM UTC — based on Prometheus timeline]
*Impact:*     [Who/what is affected — e.g., "All checkout flows"]
*Status:*     Investigating

*Roles:*
• IC (Incident Commander):  @[name]
• Technical Lead:            @[name] ← NEEDED
• Comms Lead (status page):  @[name] ← NEEDED
• Scribe (timeline):         @[name] ← NEEDED

*Notify:* @sre-team @oncall-lead @engineering-managers

*Links:*
• Grafana: https://grafana.company.com/d/prod-overview
• Runbooks: https://wiki.company.com/runbooks
• Status page admin: https://status.company.com/admin
• PagerDuty incident: [link]

━━━━━━━━━━━━━━━━━━━━━━━━━━
📌 Status page updated: INVESTIGATING
📌 Next update: [HH:MM UTC] (15 min)
```

---

## SEV2 — High

```
🟠 *SEV2 INCIDENT DECLARED*
━━━━━━━━━━━━━━━━━━━━━━━━━━
*Issue:*    [Brief description]
*Service:*  [Affected service]
*Started:*  [HH:MM UTC]
*Impact:*   [Scope]
*Status:*   Investigating

*IC:* @[name] | *TL:* @[name]

*Links:* [Grafana] | [Runbook]
Status page updated: INVESTIGATING
```

---

## Status Update Template (every 15 min during incident)

```
[HH:MM UTC] STATUS UPDATE #[N]
━━━━━━━━━━━━━━━━━━━━━━━━━━
*Status:*     INVESTIGATING / IDENTIFIED / MONITORING / RESOLVED
*Blast radius:* [X]% of users | [service name] | [region]
*Current focus:* [What the team is working on right now]
*Ruled out:*  [Hypotheses eliminated]
*ETA:*        [Only include if confident — "Unknown" is better than wrong ETA]
*Next update:* [HH:MM UTC]
```

---

## Mitigation Announcement

```
[HH:MM UTC] 🟡 MITIGATION APPLIED
━━━━━━━━━━━━━━━━━━━━━━━━━━
We have applied a mitigation: [what was done — e.g., rolled back deployment v2.3.1]
Error rate showing improvement. Monitoring for stability.
Will confirm resolution in 5 minutes.
Status page: Updated to "Monitoring"
```

---

## All-Clear Message

```
[HH:MM UTC] ✅ INCIDENT RESOLVED
━━━━━━━━━━━━━━━━━━━━━━━━━━
Service has been restored. Error rate back to baseline.

*Summary:*
• Duration: ~[X] minutes
• Root cause: [one sentence — or "under investigation"]
• Mitigation: [what was done]
• Users affected: ~[N]

*Next steps:*
• Post-mortem scheduled: [DATE+TIME]
• Action items will be tracked in JIRA project OPS
• Status page: Resolved ✅

Thank you to everyone who responded. 
@sre-team @oncall-team
```

---

## Hypothesis Testing (post in channel as you go)

```
[HH:MM UTC] 🔍 HYPOTHESIS: [What you think is wrong]
  Evidence for: [What supports this theory]
  Evidence against: [What contradicts it]
  Testing: [What you're doing to confirm/deny]
  Timer: 10 min (IC call pivot at HH:MM)
```

```
[HH:MM UTC] ❌ HYPOTHESIS RULED OUT: [hypothesis name]
  Reason: [Why it was eliminated]
  Next hypothesis: [New theory]
```

```
[HH:MM UTC] ✅ HYPOTHESIS CONFIRMED: [what is causing the incident]
  Evidence: [What confirmed it]
  Fix: [What will be done]
  Risk of fix: [Low/Medium/High]
  Applying now...
```
