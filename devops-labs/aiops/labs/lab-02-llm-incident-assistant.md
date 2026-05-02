# Lab 02: LLM-Powered Incident Assistant

**Difficulty**: Advanced | **Time**: 60 minutes  
**Goal**: Build a Slack bot that uses Claude to automatically diagnose production incidents and suggest remediation steps.

---

## Architecture

```
PagerDuty Alert → Webhook → Python Bot
                               │
                    ┌──────────┼────────────┐
                    │          │            │
             Prometheus    Kubernetes   Git Log
             (metrics)    (pod status)  (recent changes)
                    │          │            │
                    └──────────┴────────────┘
                               │
                         Claude API
                               │
                        Slack Channel
                        (diagnosis + steps)
```

---

## Part 1: Setup

```bash
mkdir llm-ops-assistant && cd llm-ops-assistant
pip install anthropic slack-bolt flask kubernetes prometheus-api-client

export ANTHROPIC_API_KEY="sk-ant-..."
export SLACK_BOT_TOKEN="xoxb-..."
export SLACK_SIGNING_SECRET="..."
```

---

## Part 2: Incident Context Gatherer

```python
# context_gatherer.py
"""Gather incident context from multiple sources."""

import subprocess
import json
from datetime import datetime, timedelta
from typing import Optional


def get_kubernetes_context(namespace: str = "production") -> dict:
    """Gather K8s state for incident analysis."""
    context = {}

    # Pod status
    result = subprocess.run(
        ["kubectl", "get", "pods", "-n", namespace, "-o", "json"],
        capture_output=True, text=True, timeout=30
    )
    if result.returncode == 0:
        pods = json.loads(result.stdout)
        context["pods"] = []
        for pod in pods.get("items", []):
            name = pod["metadata"]["name"]
            phase = pod["status"].get("phase", "Unknown")
            restarts = sum(
                cs.get("restartCount", 0)
                for cs in pod["status"].get("containerStatuses", [])
            )
            context["pods"].append({
                "name": name,
                "phase": phase,
                "restarts": restarts,
                "ready": all(
                    cs.get("ready", False)
                    for cs in pod["status"].get("containerStatuses", [])
                )
            })

    # Recent events
    result = subprocess.run(
        ["kubectl", "get", "events", "-n", namespace,
         "--field-selector", "type=Warning",
         "--sort-by=.lastTimestamp",
         "-o", "json"],
        capture_output=True, text=True, timeout=30
    )
    if result.returncode == 0:
        events = json.loads(result.stdout)
        context["recent_events"] = [
            f"{e['reason']}: {e['message']}"
            for e in events.get("items", [])[-10:]  # Last 10 warnings
        ]

    # Deployment rollout history
    result = subprocess.run(
        ["kubectl", "rollout", "history", "deployment", "-n", namespace],
        capture_output=True, text=True, timeout=30
    )
    context["deployment_history"] = result.stdout if result.returncode == 0 else "unavailable"

    return context


def get_recent_git_changes(hours: int = 4) -> str:
    """Get recent git commits that might be related to the incident."""
    result = subprocess.run(
        ["git", "log", "--oneline",
         f"--since={hours} hours ago"],
        capture_output=True, text=True, timeout=15
    )
    if result.returncode == 0 and result.stdout:
        return result.stdout
    return "No recent commits or git unavailable"


def get_prometheus_summary(prom_url: str, namespace: str) -> str:
    """Get key metrics summary from Prometheus."""
    try:
        from prometheus_api_client import PrometheusConnect
        prom = PrometheusConnect(url=prom_url, disable_ssl=True)

        queries = {
            "error_rate": f'sum(rate(http_requests_total{{namespace="{namespace}",status=~"5.."}}[5m])) / sum(rate(http_requests_total{{namespace="{namespace}"}}[5m]))',
            "p99_latency": f'histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{{namespace="{namespace}"}}[5m])) by (le)) * 1000',
            "pod_restarts": f'sum(increase(kube_pod_container_status_restarts_total{{namespace="{namespace}"}}[1h]))',
        }

        results = []
        for metric_name, query in queries.items():
            result = prom.custom_query(query)
            if result:
                value = float(result[0]["value"][1])
                results.append(f"{metric_name}: {value:.2f}")

        return "\n".join(results) if results else "Metrics unavailable"

    except Exception as e:
        return f"Prometheus unavailable: {e}"
```

---

## Part 3: Claude-Powered Diagnosis

```python
# incident_analyst.py
"""Use Claude to analyze incident context and generate diagnosis."""

import anthropic
import json


def analyze_incident(
    alert_name: str,
    alert_description: str,
    k8s_context: dict,
    git_changes: str,
    metrics_summary: str,
    service_name: str = "unknown"
) -> dict:
    """
    Use Claude to analyze the incident and generate actionable response.
    Returns structured diagnosis with immediate steps and root cause hypotheses.
    """
    client = anthropic.Anthropic()

    # Format context for Claude
    pods_summary = "\n".join([
        f"  - {p['name']}: {p['phase']}, ready={p['ready']}, restarts={p['restarts']}"
        for p in k8s_context.get("pods", [])
    ])

    events_summary = "\n".join([
        f"  - {e}" for e in k8s_context.get("recent_events", [])
    ])

    system_prompt = """You are an expert SRE (Site Reliability Engineer) helping diagnose production incidents.
    
You have deep knowledge of:
- Kubernetes pod failures, resource issues, and networking
- Application performance problems (memory leaks, CPU spikes, slow queries)
- Database and cache issues
- Deployment rollback procedures
- Common cloud infrastructure failures

When analyzing incidents:
1. Be specific and actionable — not vague
2. Prioritize immediate mitigation over root cause investigation
3. Use the evidence provided — don't speculate without data
4. List commands with exact kubectl/bash syntax
5. Rank hypotheses by probability based on evidence

Format your response as JSON with these keys:
- severity: "critical" | "high" | "medium"
- immediate_actions: list of specific commands to run RIGHT NOW
- root_cause_hypotheses: list of {hypothesis, evidence, probability}
- investigation_commands: list of commands to gather more info
- estimated_resolution_time: "X minutes"
- escalation_needed: true/false"""

    user_message = f"""## Active Incident

**Alert**: {alert_name}
**Service**: {service_name}
**Description**: {alert_description}

## Current Pod Status
{pods_summary or "No pod data available"}

## Recent Kubernetes Events (Warnings)
{events_summary or "No warning events"}

## Key Metrics (last 5 min)
{metrics_summary}

## Recent Deployments / Git Changes (last 4 hours)
{git_changes}

## Deployment History
{k8s_context.get('deployment_history', 'Unavailable')[:500]}

---
Please analyze this incident and provide a structured diagnosis with immediate actions."""

    message = client.messages.create(
        model="claude-opus-4-5",
        max_tokens=2048,
        system=system_prompt,
        messages=[{"role": "user", "content": user_message}]
    )

    response_text = message.content[0].text

    # Parse JSON response
    try:
        # Extract JSON from response (Claude might wrap it in markdown)
        import re
        json_match = re.search(r'\{.*\}', response_text, re.DOTALL)
        if json_match:
            return json.loads(json_match.group())
    except (json.JSONDecodeError, AttributeError):
        pass

    # Fallback: return as plain text in structured format
    return {
        "severity": "unknown",
        "immediate_actions": ["Check kubectl get pods -n production",
                              "kubectl get events -n production --sort-by=.lastTimestamp"],
        "root_cause_hypotheses": [{"hypothesis": response_text, "probability": "unknown"}],
        "investigation_commands": [],
        "estimated_resolution_time": "unknown",
        "escalation_needed": True
    }
```

---

## Part 4: Slack Bot

```python
# slack_bot.py
"""Slack bot that responds to incident channels."""

from slack_bolt import App
from slack_bolt.adapter.flask import SlackRequestHandler
from flask import Flask, request
import os

from context_gatherer import get_kubernetes_context, get_recent_git_changes, get_prometheus_summary
from incident_analyst import analyze_incident

flask_app = Flask(__name__)
app = App(
    token=os.environ["SLACK_BOT_TOKEN"],
    signing_secret=os.environ["SLACK_SIGNING_SECRET"]
)
handler = SlackRequestHandler(app)


def format_diagnosis_message(diagnosis: dict, alert_name: str) -> list:
    """Format Claude's diagnosis into Slack blocks."""
    severity_emoji = {
        "critical": "🔴",
        "high": "🟠",
        "medium": "🟡",
        "unknown": "⚪"
    }.get(diagnosis.get("severity", "unknown"), "⚪")

    blocks = [
        {
            "type": "header",
            "text": {
                "type": "plain_text",
                "text": f"{severity_emoji} AI Incident Analysis: {alert_name}"
            }
        },
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": f"*Estimated Resolution*: {diagnosis.get('estimated_resolution_time', 'Unknown')}"
                        + ("\n⚠️ *Escalation Recommended*" if diagnosis.get('escalation_needed') else "")
            }
        },
        {"type": "divider"},
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": "*🚨 Immediate Actions*\n" +
                        "\n".join(f"```{cmd}```" for cmd in diagnosis.get("immediate_actions", [])[:3])
            }
        },
        {"type": "divider"},
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": "*🔍 Root Cause Hypotheses*\n" +
                        "\n".join(
                            f"• [{h.get('probability', '?')}] {h.get('hypothesis', 'Unknown')}"
                            for h in diagnosis.get("root_cause_hypotheses", [])[:3]
                        )
            }
        }
    ]

    if diagnosis.get("investigation_commands"):
        blocks.append({
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": "*🔬 Investigation Commands*\n" +
                        "\n".join(f"• `{cmd}`" for cmd in diagnosis.get("investigation_commands", [])[:5])
            }
        })

    return blocks


@app.event("app_mention")
def handle_mention(event, say, client):
    """Handle @bot mentions in channels."""
    channel = event["channel"]
    text = event.get("text", "")

    # React to show we're processing
    client.reactions_add(channel=channel, timestamp=event["ts"], name="loading-indicator")

    say(text="🔍 Analyzing incident context... (30-60 seconds)", channel=channel)

    try:
        # Gather context
        namespace = "production"
        if "namespace:" in text:
            namespace = text.split("namespace:")[1].strip().split()[0]

        k8s_ctx = get_kubernetes_context(namespace)
        git_changes = get_recent_git_changes(hours=4)
        metrics = get_prometheus_summary(
            os.getenv("PROMETHEUS_URL", "http://prometheus:9090"),
            namespace
        )

        # Ask Claude to analyze
        diagnosis = analyze_incident(
            alert_name="Manual Investigation Request",
            alert_description=text,
            k8s_context=k8s_ctx,
            git_changes=git_changes,
            metrics_summary=metrics,
            service_name="unknown"
        )

        # Post diagnosis
        blocks = format_diagnosis_message(diagnosis, "Incident Analysis")
        say(blocks=blocks, channel=channel)

    except Exception as e:
        say(text=f"❌ Analysis failed: {e}", channel=channel)
    finally:
        client.reactions_remove(channel=channel, timestamp=event["ts"], name="loading-indicator")


@flask_app.route("/slack/events", methods=["POST"])
def slack_events():
    return handler.handle(request)


@flask_app.route("/health")
def health():
    return {"status": "ok"}


if __name__ == "__main__":
    flask_app.run(host="0.0.0.0", port=3000)
```

---

## Part 5: Test the Assistant

```bash
# Start the bot
python slack_bot.py &

# Simulate an incident context
python3 << 'EOF'
from context_gatherer import get_kubernetes_context
from incident_analyst import analyze_incident
import json

# Mock context
k8s_ctx = {
    "pods": [
        {"name": "api-abc123", "phase": "Running", "ready": True, "restarts": 0},
        {"name": "api-def456", "phase": "CrashLoopBackOff", "ready": False, "restarts": 8},
        {"name": "api-ghi789", "phase": "OOMKilled", "ready": False, "restarts": 3}
    ],
    "recent_events": [
        "OOMKilled: Container api was OOM killed",
        "BackOff: Back-off restarting failed container",
        "Failed: Failed to pull image myapp:v2.1.0"
    ],
    "deployment_history": "Deployed v2.1.0 14 minutes ago"
}

diagnosis = analyze_incident(
    alert_name="HighErrorRate — API Service",
    alert_description="Error rate 15%, burning error budget 150x",
    k8s_context=k8s_ctx,
    git_changes="2024-01-15 14:00 - feat: add new caching layer (v2.1.0)",
    metrics_summary="error_rate: 0.15\np99_latency: 2300ms\npod_restarts: 11.0"
)

print(json.dumps(diagnosis, indent=2))
EOF
```

---

## Cleanup

```bash
pkill -f slack_bot.py 2>/dev/null || true
cd ..
rm -rf llm-ops-assistant
```

## What You Learned

- [x] Gathering incident context from K8s, Prometheus, and Git
- [x] Structuring prompts for Claude to perform root cause analysis
- [x] Building a Slack bot with slack-bolt
- [x] Formatting AI responses as Slack blocks for readability
- [x] Integrating LLM reasoning with real infrastructure data
