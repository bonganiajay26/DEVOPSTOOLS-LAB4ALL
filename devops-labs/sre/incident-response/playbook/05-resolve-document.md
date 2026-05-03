# Phase 5 — Resolve & Document

## Timeline After Stabilization

```
T+0h    Service restored → declare all-clear
T+1h    Write initial timeline while memory is fresh
T+24h   Post-mortem document circulated for async review
T+48h   Blameless post-mortem meeting (30–60 min)
T+72h   Action items assigned with owners and deadlines
T+1wk   First check-in on action item progress
T+sprint Close action items in current or next sprint
```

---

## The Blameless Post-Mortem

### Why Blameless?

```
Blame-driven post-mortems → engineers hide mistakes
                          → same incidents repeat
                          → on-call becomes feared

Blameless post-mortems → engineers report near-misses
                       → system improvements happen
                       → on-call is manageable

Key principle:
  "We assume everyone acted in good faith with the information
   available to them at the time. Failures are system problems,
   not people problems."
```

### What to Investigate (not who to blame)

```
GOOD QUESTIONS:
  "What made this failure mode possible?"
  "Why didn't our monitoring catch this earlier?"
  "Why did this process fail?"
  "What would have helped detect this faster?"

BAD QUESTIONS:
  "Why did John push that change without testing?"
  "Who approved this deployment?"
  "Which engineer was responsible?"
```

---

## Post-Mortem Template

See `templates/post-mortem.md` for the full copyable template.

### Required sections:

```markdown
# Post-Mortem: [Title] — [Date]

## Summary (2–3 sentences)
What happened, how many users were affected, how long it lasted.

## Impact
- Duration: X minutes (HH:MM UTC – HH:MM UTC)
- Users affected: ~N users (~X% of total)
- Revenue impact: $X (if measurable)
- SLA breached: Yes/No

## Timeline (UTC)
| Time  | Event |
|-------|-------|
| 14:30 | Deployment of v2.3.1 completed |
| 14:32 | Alert fired: error_rate > 5% |
| 14:34 | IC acknowledged, incident declared |
| 14:38 | Hypothesis: DB slow — RULED OUT (pg_stat_activity clean) |
| 14:41 | Hypothesis: bad deploy — CONFIRMED (errors match deploy time) |
| 14:43 | Rollback initiated |
| 14:45 | Error rate returned to baseline |
| 14:50 | All-clear declared |

## Root Cause
One clear sentence:
"Deployment v2.3.1 introduced a database query without an index,
causing full table scans that saturated the DB connection pool
under production load (not reproduced in staging due to smaller dataset)."

## Contributing Factors
- No index on new column added in migration
- Staging database has 1000 rows; production has 50M rows
- No slow query alert configured on the RDS instance
- Code review didn't catch missing index

## What Went Well
- Detection was fast (2 min from symptom to alert)
- On-call acknowledged within 1 minute
- Rollback was straightforward and well-practiced
- Runbook was accurate

## What Could Be Improved
- Slow query alert should have fired before user impact
- Staging/prod data parity for performance testing
- Database migration review checklist

## Action Items
| Action | Owner | Due | Priority |
|--------|-------|-----|---------|
| Add slow query alert (> 5s) to RDS | @platform-team | Jan 22 | P1 |
| Add index to new_column | @backend-team | Jan 17 | P1 (hotfix) |
| Create DB migration checklist | @DBA + @backend-lead | Jan 29 | P2 |
| Improve staging data volume for perf tests | @platform-team | Feb 5 | P2 |
| Add performance test to CI for query-heavy PRs | @devops-team | Feb 12 | P3 |
```

---

## Action Item Standards

```
Every action item MUST have:
  □ Clear, specific description (not "improve monitoring")
  □ Single owner (not "the team")
  □ Deadline
  □ Priority (P1 = must do this sprint, P2 = next sprint, P3 = backlog)

GOOD action item:
  "Add alert: pg_stat_activity count > 80% of max_connections
   → warning in monitoring. Owner: @alice. Due: Jan 20."

BAD action item:
  "Improve database monitoring"
  (Who? What specifically? By when?)
```

---

## Tracking Action Items to Completion

At VersatileCommerce, this was the #1 factor in reducing repeat incidents:

```python
# automation/track-action-items.py
# Run weekly: python track-action-items.py
# Pulls action items from JIRA/Linear, reports overdue ones to Slack

import requests, datetime

def get_overdue_items(jira_client):
    """Find post-mortem action items past their due date."""
    issues = jira_client.search_issues(
        'project = OPS AND labels = postmortem AND status != Done'
        ' AND duedate < now()'
    )
    return [{
        "key":     issue.key,
        "summary": issue.fields.summary,
        "due":     issue.fields.duedate,
        "owner":   issue.fields.assignee.displayName,
        "days_overdue": (
            datetime.date.today() -
            datetime.date.fromisoformat(issue.fields.duedate)
        ).days
    } for issue in issues]

def post_weekly_report(overdue_items, slack_webhook):
    if not overdue_items:
        return

    blocks = [{
        "type": "section",
        "text": {
            "type": "mrkdwn",
            "text": f"*Weekly Post-Mortem Action Item Review*\n"
                    f"*{len(overdue_items)} items overdue:*"
        }
    }]
    for item in sorted(overdue_items, key=lambda x: -x["days_overdue"]):
        blocks.append({
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": f"• [{item['key']}] {item['summary']}\n"
                        f"  Owner: {item['owner']} | "
                        f"  {item['days_overdue']} days overdue"
            }
        })

    requests.post(slack_webhook, json={"blocks": blocks})
```

---

## Reducing Repeat Incidents

The 50% MTTR reduction came from three practices:

```
1. Automated SLO burn-rate detection (instead of manual thresholds)
   → MTTD: 8 min → 45 seconds

2. Pre-written runbooks for top 10 incident patterns
   → MTTR for known patterns: 90 min → 8 min (engineer just runs the script)

3. Quarterly incident response drills
   → Engineers know the playbook under pressure
   → Runbooks are tested and kept accurate
   → Rollback procedures are muscle memory

The single highest-ROI action: runbooks.
Engineers were spending 30–60 minutes figuring out what to check.
Pre-written runbooks turn that into 2 minutes.
```
