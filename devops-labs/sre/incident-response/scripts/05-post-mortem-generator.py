#!/usr/bin/env python3
"""
Script 05 — Post-Mortem Generator
Auto-populates a blameless post-mortem from:
  - Incident declaration metadata (from 01-declare-incident.sh)
  - Prometheus metrics (error rate during incident)
  - Kubernetes events during the incident window
  - Deployment history

Usage:
  python3 05-post-mortem-generator.py \
    --incident-file /tmp/incident-20240115-1432.json \
    --resolved-at "14:50 UTC" \
    --namespace production

Output: post-mortem-YYYYMMDD-<title>.md
"""

import argparse
import json
import os
import subprocess
from datetime import datetime, timedelta
from pathlib import Path


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--incident-file", help="JSON file from 01-declare-incident.sh")
    p.add_argument("--resolved-at",   default="",         help="Resolution time (e.g. '14:50 UTC')")
    p.add_argument("--root-cause",    default="",         help="Brief root cause description")
    p.add_argument("--namespace",     default="production")
    p.add_argument("--severity",      default="",         help="SEV1/SEV2/SEV3 (if no incident file)")
    p.add_argument("--title",         default="",         help="Incident title (if no incident file)")
    p.add_argument("--declared-at",   default="",         help="Declaration time (if no incident file)")
    p.add_argument("--output-dir",    default=".",        help="Output directory")
    return p.parse_args()


def load_incident_metadata(incident_file):
    """Load incident metadata from declaration script output."""
    if incident_file and Path(incident_file).exists():
        with open(incident_file) as f:
            return json.load(f)
    return {}


def get_k8s_events(namespace, since_minutes=60):
    """Get Kubernetes warning events from the incident window."""
    try:
        result = subprocess.run(
            ["kubectl", "get", "events", "-n", namespace,
             "--field-selector", "type=Warning",
             "--sort-by=.lastTimestamp",
             "-o", "json"],
            capture_output=True, text=True, timeout=15
        )
        if result.returncode != 0:
            return []

        events = json.loads(result.stdout)
        return [
            f"[{e['lastTimestamp']}] {e['reason']}: {e['message'][:100]}"
            for e in events.get("items", [])[-10:]
        ]
    except Exception:
        return []


def get_deployment_history(namespace):
    """Get recent deployment history to find what changed."""
    try:
        result = subprocess.run(
            ["kubectl", "rollout", "history", "deployment", "-n", namespace],
            capture_output=True, text=True, timeout=10
        )
        return result.stdout if result.returncode == 0 else ""
    except Exception:
        return ""


def get_prometheus_summary(prom_url, namespace):
    """Attempt to get error rate metrics from Prometheus."""
    import urllib.request, urllib.parse
    try:
        query = f'sum(rate(http_requests_total{{namespace="{namespace}",status=~"5.."}}[5m]))'
        url = f"{prom_url}/api/v1/query?" + urllib.parse.urlencode({"query": query})
        with urllib.request.urlopen(url, timeout=5) as r:
            data = json.loads(r.read())
            results = data.get("data", {}).get("result", [])
            if results:
                return float(results[0]["value"][1])
    except Exception:
        pass
    return None


def generate_post_mortem(incident, resolved_at, root_cause, namespace):
    """Generate a complete blameless post-mortem document."""

    declared_at = incident.get("declared_at", "FILL IN")
    severity    = incident.get("severity",    "SEV?")
    title       = incident.get("title",       "FILL IN")
    service     = incident.get("service",     "FILL IN")
    ic          = incident.get("ic",          "FILL IN")
    timestamp   = incident.get("timestamp",   datetime.utcnow().strftime("%Y%m%d-%H%M"))

    # Get contextual data
    k8s_events = get_k8s_events(namespace)
    deploy_history = get_deployment_history(namespace)
    today = datetime.utcnow().strftime("%Y-%m-%d")

    # Calculate approximate duration
    duration = "FILL IN"
    try:
        fmt = "%H:%M UTC"
        start = datetime.strptime(declared_at, fmt)
        end   = datetime.strptime(resolved_at, fmt) if resolved_at else None
        if end:
            mins = int((end - start).total_seconds() / 60)
            duration = f"{mins} minutes"
    except Exception:
        pass

    # Action item placeholder count
    post_mortem = f"""# Post-Mortem: {title}
**Date**: {today}
**Severity**: {severity}
**Status**: Draft — needs review

---

## Summary

<!-- 2–3 sentences: what happened, blast radius, duration -->
On {today}, `{service}` experienced {severity.lower()} degradation starting at {declared_at}.
The incident lasted approximately {duration} and affected [X]% of users attempting to [action].
Root cause: {root_cause or "**FILL IN** — one clear sentence"}

---

## Impact

| Metric | Value |
|--------|-------|
| Duration | {duration} |
| Declared at | {declared_at} |
| Resolved at | {resolved_at or "**FILL IN**"} |
| Users affected | **FILL IN** (query: unique users with errors in window) |
| Revenue impact | **FILL IN** ($X estimated) |
| SLA breached | **FILL IN** (Yes / No) |
| Error budget consumed | **FILL IN** (X min of Y min monthly budget) |

---

## Timeline (UTC)

> Tip: Use your incident Slack channel history to fill this in.
> Every hypothesis tested, every command run, every decision made.

| Time | Event | Who |
|------|-------|-----|
| {declared_at} | Alert fired: **FILL IN alert name** | Prometheus |
| +2 min | Incident declared, IC: @{ic} | @{ic} |
| +5 min | Blast radius assessed: **FILL IN** | @{ic} |
| +? min | Hypothesis 1: **FILL IN** | @tech-lead |
| +? min | Hypothesis 1 ruled out because: **FILL IN** | @tech-lead |
| +? min | Hypothesis 2: **FILL IN** — CONFIRMED | @tech-lead |
| +? min | Mitigation applied: **FILL IN** (rollback/scale/flag) | @tech-lead |
| +? min | Error rate returned to baseline | Prometheus |
| {resolved_at or "**FILL IN**"} | All-clear declared | @{ic} |

---

## Root Cause

<!-- One clear sentence. NOT "human error". NOT "the developer". -->
<!-- Example: "Deployment v2.3.1 introduced a missing database index, -->
<!--           causing full table scans that saturated connection pool at production scale." -->

**FILL IN**

---

## Contributing Factors

<!-- Why was this failure mode possible? System/process issues, not people. -->

1. **FILL IN** — e.g., "No slow query alert on RDS"
2. **FILL IN** — e.g., "Staging dataset too small to reproduce under load"
3. **FILL IN** — e.g., "Database migration review had no performance checklist"

---

## Detection

| | Time |
|---|---|
| Symptom started | **FILL IN** |
| Alert fired | {declared_at} |
| IC acknowledged | **FILL IN** |
| MTTD (symptom → alert) | **FILL IN** |
| MTTA (alert → ACK) | **FILL IN** |

**Was detection fast enough?** FILL IN
**What would have caught this sooner?** FILL IN

---

## Kubernetes Events During Incident

```
{chr(10).join(k8s_events) if k8s_events else "No events captured — run during incident"}
```

---

## Recent Deployment History

```
{deploy_history[:800] if deploy_history else "Run: kubectl rollout history deployment -A"}
```

---

## What Went Well

<!-- Genuinely celebrate the things that worked -->

1. **FILL IN** — e.g., "Alert fired within 90 seconds of symptom"
2. **FILL IN** — e.g., "Rollback procedure was fast and well-practiced"
3. **FILL IN** — e.g., "Post-incident communication was clear and timely"

---

## What Could Be Improved

<!-- Process/system improvements. Not "be more careful." -->

1. **FILL IN** — e.g., "Slow query alert should fire before user impact"
2. **FILL IN** — e.g., "Runbook for this scenario didn't exist"
3. **FILL IN** — e.g., "Staging data too small to catch this pattern"

---

## Action Items

| # | Action | Owner | Due | Priority | Status |
|---|--------|-------|-----|----------|--------|
| 1 | **FILL IN specific action** | @owner | {(datetime.utcnow() + timedelta(days=7)).strftime("%b %d")} | P1 | Open |
| 2 | **FILL IN specific action** | @owner | {(datetime.utcnow() + timedelta(days=14)).strftime("%b %d")} | P2 | Open |
| 3 | **FILL IN specific action** | @owner | {(datetime.utcnow() + timedelta(days=21)).strftime("%b %d")} | P3 | Open |

> **P1** = must complete this sprint
> **P2** = next sprint
> **P3** = backlog, but tracked

---

## Action Item Standards
Every action item must be specific, owned, and time-bounded.

❌ Bad: "Improve monitoring"
✅ Good: "Add Prometheus alert: pg_stat_activity > 80% of max_connections → warning. Owner: @alice. Due: Jan 20."

---

## Blameless Note

This post-mortem focuses on systemic improvements, not individual blame.
All engineers involved acted in good faith with the information available.
The goal is to make our systems and processes more resilient.

---

*Post-mortem template generated by `scripts/05-post-mortem-generator.py`*
*Review and complete within 48 hours of incident resolution.*
*Schedule the post-mortem meeting: 30 min, all responders + team lead invited.*
"""
    return post_mortem, timestamp


def main():
    args = parse_args()

    # Load or construct incident metadata
    incident = load_incident_metadata(args.incident_file)

    # Override with CLI args if provided
    if args.severity:   incident["severity"]    = args.severity
    if args.title:      incident["title"]       = args.title
    if args.declared_at: incident["declared_at"] = args.declared_at

    if not incident:
        print("No incident metadata found. Generating blank template...")
        incident = {
            "severity":   "SEV?",
            "title":      "Incident Title",
            "service":    "service-name",
            "ic":         "ic-name",
            "declared_at": datetime.utcnow().strftime("%H:%M UTC"),
            "timestamp":   datetime.utcnow().strftime("%Y%m%d-%H%M"),
        }

    print(f"\nGenerating post-mortem for: {incident.get('title', 'Unknown')}")
    print(f"Namespace: {args.namespace}")

    post_mortem, timestamp = generate_post_mortem(
        incident,
        args.resolved_at,
        args.root_cause,
        args.namespace
    )

    # Save output
    safe_title = incident.get("title", "incident").lower().replace(" ", "-")
    safe_title = "".join(c for c in safe_title if c.isalnum() or c == "-")[:40]
    output_file = Path(args.output_dir) / f"post-mortem-{timestamp[:8]}-{safe_title}.md"

    with open(output_file, "w") as f:
        f.write(post_mortem)

    print(f"\nPost-mortem saved: {output_file}")
    print("\nNext steps:")
    print("  1. Fill in all FILL IN sections using your incident channel history")
    print("  2. Circulate for async review within 24 hours")
    print("  3. Hold 30-minute meeting within 48 hours")
    print("  4. Assign all action items before closing the meeting")
    print(f"\n  Open: {output_file}")


if __name__ == "__main__":
    main()
