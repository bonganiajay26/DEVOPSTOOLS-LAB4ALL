# AIOps Core Concepts

## Anomaly Detection in Metrics

```python
# Prophet-based anomaly detection for time series metrics
# Detects unusual patterns (e.g., request rate at 3AM when it should be near zero)

from prophet import Prophet
import pandas as pd
import numpy as np
from prometheus_api_client import PrometheusConnect

def detect_metric_anomalies(metric_query: str, lookback_days: int = 30) -> pd.DataFrame:
    """
    Fetch Prometheus metric, train Prophet model, detect anomalies.
    """
    # Fetch historical data
    prom = PrometheusConnect(url="http://prometheus.monitoring:9090")
    end_time = pd.Timestamp.now()
    start_time = end_time - pd.Timedelta(days=lookback_days)

    data = prom.get_metric_range_data(
        metric_query,
        start_time=start_time,
        end_time=end_time,
        chunk_size=pd.Timedelta(days=1)
    )

    df = pd.DataFrame([
        {"ds": pd.Timestamp(v[0], unit='s'), "y": float(v[1])}
        for metric in data
        for v in metric['values']
    ])

    # Train Prophet (handles seasonality, holidays, trends)
    model = Prophet(
        seasonality_mode='multiplicative',
        changepoint_prior_scale=0.05,   # Sensitivity to trend changes
        interval_width=0.99,            # 99% confidence interval
        daily_seasonality=True,
        weekly_seasonality=True,
    )
    model.fit(df[df['ds'] < end_time - pd.Timedelta(hours=1)])  # Train on all but last hour

    # Predict for recent data
    future = model.make_future_dataframe(periods=60, freq='min')
    forecast = model.predict(future)

    # Merge with actual values
    merged = df.merge(
        forecast[['ds', 'yhat', 'yhat_lower', 'yhat_upper']],
        on='ds', how='inner'
    )

    # Flag anomalies (outside prediction interval)
    merged['anomaly'] = (
        (merged['y'] > merged['yhat_upper']) |
        (merged['y'] < merged['yhat_lower'])
    )
    merged['deviation'] = (merged['y'] - merged['yhat']) / merged['yhat']

    anomalies = merged[merged['anomaly'] & (merged['ds'] > end_time - pd.Timedelta(hours=1))]

    return anomalies

# Run periodically via CronJob
anomalies = detect_metric_anomalies('rate(http_requests_total{job="api"}[5m])')
if not anomalies.empty:
    alert_slack(f"Anomaly detected in request rate: {anomalies}")
```

---

## Log Anomaly Detection

```python
# Drain3 — online log clustering and anomaly detection
from drain3 import TemplateMiner
from drain3.template_miner_config import TemplateMinerConfig
import json

class LogAnomalyDetector:
    def __init__(self):
        config = TemplateMinerConfig()
        config.load("drain3.ini")
        self.miner = TemplateMiner(config=config)
        self.template_counts = {}
        self.baseline_window = 1000   # Lines to establish baseline

    def process_log_line(self, log_line: str) -> dict:
        result = self.miner.add_log_message(log_line)
        template_id = result["cluster_id"]
        template = result["template_mined"]

        # Count occurrences of each template
        self.template_counts[template_id] = \
            self.template_counts.get(template_id, 0) + 1

        # Detect new template (unknown log pattern)
        if result["change_type"] == "cluster_created":
            return {
                "anomaly": True,
                "type": "new_log_pattern",
                "template": template,
                "line": log_line,
                "severity": "medium"
            }

        return {"anomaly": False, "template_id": template_id}

    def detect_volume_spike(self, template_id: str, window_count: int, expected: float) -> bool:
        """Alert if log pattern appears much more than expected."""
        z_score = (window_count - expected) / (expected ** 0.5)
        return z_score > 3.0  # 3 sigma = anomaly
```

---

## Intelligent Alert Correlation

```python
# Correlate related alerts → single incident
# Prevents alert storms from a single root cause
# Example: DB failure → app errors → slow responses → timeouts
# All should be ONE incident, not 50 separate alerts

from collections import defaultdict
from datetime import datetime, timedelta

class AlertCorrelator:
    def __init__(self, correlation_window_minutes: int = 5):
        self.window = timedelta(minutes=correlation_window_minutes)
        self.active_incidents = {}

    def process_alert(self, alert: dict) -> str:
        """
        Returns incident_id that this alert belongs to.
        Creates new incident if no correlated one found.
        """
        alert_time = datetime.fromisoformat(alert['startsAt'])

        # Find related incidents based on:
        # 1. Temporal proximity (within 5 minutes)
        # 2. Topological relationship (same service or dependent service)
        # 3. Causal relationship (DB down → app errors)

        for incident_id, incident in self.active_incidents.items():
            if self._is_correlated(alert, incident):
                incident['alerts'].append(alert)
                return incident_id

        # Create new incident
        incident_id = f"INC-{len(self.active_incidents)+1:04d}"
        self.active_incidents[incident_id] = {
            'id': incident_id,
            'alerts': [alert],
            'start_time': alert_time,
            'root_cause_candidate': self._identify_root_cause([alert])
        }
        return incident_id

    def _is_correlated(self, new_alert: dict, incident: dict) -> bool:
        """Check if new alert is related to existing incident."""
        # Time-based correlation
        incident_time = incident['start_time']
        alert_time = datetime.fromisoformat(new_alert['startsAt'])
        if abs((alert_time - incident_time).total_seconds()) > self.window.total_seconds():
            return False

        # Service topology correlation (from service map)
        incident_services = {a['labels'].get('service') for a in incident['alerts']}
        new_service = new_alert['labels'].get('service')
        if new_service in incident_services or \
           self._is_downstream(new_service, incident_services):
            return True

        return False

    def _identify_root_cause(self, alerts: list) -> str:
        """Simple heuristic: earliest alert from most upstream service."""
        sorted_alerts = sorted(alerts, key=lambda a: a['startsAt'])
        return sorted_alerts[0]['labels'].get('alertname', 'unknown')
```

---

## AI-Powered Incident Response (LLM-Based)

```python
# Use Claude/GPT to assist with incident diagnosis
import anthropic

def ai_incident_assistant(
    alert_context: dict,
    recent_logs: str,
    metrics_summary: str,
    recent_deployments: list
) -> str:
    """
    Given incident context, generate diagnosis and recommended actions.
    """
    client = anthropic.Anthropic()

    prompt = f"""You are an expert SRE helping diagnose a production incident.

## Alert
{alert_context}

## Recent Logs (last 50 lines)
{recent_logs}

## Key Metrics
{metrics_summary}

## Recent Deployments (last 24h)
{', '.join(recent_deployments) or 'None'}

## Task
1. What is the most likely root cause?
2. What immediate actions should the on-call engineer take?
3. What runbook should they follow?
4. What information should they gather for the post-mortem?

Be specific and actionable. Use the evidence provided."""

    message = client.messages.create(
        model="claude-opus-4-5",
        max_tokens=1024,
        messages=[{"role": "user", "content": prompt}]
    )

    return message.content[0].text

# Integration: When PagerDuty fires, AI assistant runs automatically
# Posts analysis to Slack incident channel within 30 seconds
# Engineer sees: "Most likely cause: DB connection exhaustion from auth-service v1.2.3
#                 deployed 2 hours ago. Recommend rollback first."
```

---

## Predictive Failure Detection

```python
# Predict disk exhaustion, OOM, traffic spikes before they happen

def predict_disk_exhaustion(node_metrics: pd.DataFrame) -> list:
    """
    Use linear regression to predict when disk will fill.
    Returns list of nodes at risk in next 24h.
    """
    from sklearn.linear_model import LinearRegression
    import numpy as np

    at_risk_nodes = []

    for node in node_metrics['node'].unique():
        node_data = node_metrics[node_metrics['node'] == node].sort_values('timestamp')

        if len(node_data) < 10:
            continue

        # Features: time since start, recent trend
        X = np.arange(len(node_data)).reshape(-1, 1)
        y = node_data['disk_used_percent'].values

        model = LinearRegression()
        model.fit(X, y)

        # Predict 24h ahead
        future_point = len(node_data) + (24 * 60 // 5)  # 5-min intervals
        predicted_usage = model.predict([[future_point]])[0]

        if predicted_usage > 90 and model.coef_[0] > 0:  # Growing AND will exceed 90%
            hours_to_full = (100 - y[-1]) / (model.coef_[0] * 12)  # coef per 5min
            at_risk_nodes.append({
                "node": node,
                "current_usage": y[-1],
                "predicted_24h": predicted_usage,
                "hours_to_full": hours_to_full,
                "trend": "increasing"
            })

    return at_risk_nodes

# Schedule: run every hour, alert if node will fill in < 12h
# Action: clean up old logs, expand disk, or migrate workloads
```

---

## Auto-Remediation Framework

```python
# Safe automated remediation for known issues
from typing import Callable
import kubernetes
import subprocess

class RemediationEngine:
    def __init__(self):
        self.remediation_registry: dict[str, Callable] = {
            "PodCrashLoopBackOff": self.restart_crash_loop_pod,
            "NodeDiskPressure": self.cleanup_node_disk,
            "HighMemoryPressure": self.evict_low_priority_pods,
            "ServiceEndpointsEmpty": self.restart_deployment,
        }
        self.max_auto_remediation_severity = "warning"  # Don't auto-remediate critical

    def handle_alert(self, alert: dict) -> dict:
        alert_name = alert['labels']['alertname']
        severity = alert['labels']['severity']

        # Safety gate: only auto-remediate warning level
        if severity == "critical":
            return {"action": "escalate", "reason": "Critical alerts require human review"}

        # Check if we have a remediation for this alert
        if alert_name not in self.remediation_registry:
            return {"action": "none", "reason": "No remediation registered"}

        # Check if we've already remediated this recently (avoid loops)
        if self._recently_remediated(alert):
            return {"action": "escalate", "reason": "Already attempted remediation"}

        # Execute remediation
        try:
            result = self.remediation_registry[alert_name](alert)
            self._log_remediation(alert, result)
            return {"action": "remediated", "result": result}
        except Exception as e:
            return {"action": "failed", "error": str(e)}

    def restart_crash_loop_pod(self, alert: dict) -> str:
        pod_name = alert['labels']['pod']
        namespace = alert['labels']['namespace']

        # Safety: only restart if it's CrashLoopBackOff and has restarted < 10 times
        v1 = kubernetes.client.CoreV1Api()
        pod = v1.read_namespaced_pod(pod_name, namespace)
        restart_count = pod.status.container_statuses[0].restart_count

        if restart_count > 10:
            raise Exception("Too many restarts — escalating to human")

        # Delete pod (will be recreated by Deployment controller)
        v1.delete_namespaced_pod(pod_name, namespace)
        return f"Deleted pod {pod_name} in {namespace} (restart #{restart_count})"

    def cleanup_node_disk(self, alert: dict) -> str:
        node_name = alert['labels']['instance']
        # Run cleanup script via kubectl exec on a privileged pod on that node
        result = subprocess.run([
            "kubectl", "debug", f"node/{node_name}",
            "-it", "--image=ubuntu",
            "--", "bash", "-c",
            "docker system prune -f && journalctl --vacuum-size=500M"
        ], capture_output=True, text=True, timeout=120)
        return result.stdout
```
