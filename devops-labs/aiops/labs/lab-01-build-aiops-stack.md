# Lab 01: Build an AIOps Anomaly Detection System

**Difficulty**: Advanced | **Time**: 90 minutes  
**Goal**: Deploy a real-time anomaly detection pipeline that monitors Kubernetes metrics and fires intelligent alerts.

---

## Architecture

```
Prometheus (metrics)
       │
       ▼
Python AIOps Worker (CronJob)
  ├── Fetch metrics via API
  ├── Run anomaly detection (Z-score + Prophet)
  ├── Compare to baselines
  └── Fire Alertmanager webhook if anomalous
       │
       ▼
Alertmanager → Slack / PagerDuty
```

---

## Part 1: Setup

```bash
mkdir aiops-lab && cd aiops-lab

# Prerequisites: kube-prometheus-stack running
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
kind create cluster --name aiops-lab
kubectl create namespace monitoring
helm install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --set grafana.adminPassword=admin123

kubectl wait --for=condition=Ready pod --all -n monitoring --timeout=5m
```

---

## Part 2: Anomaly Detection Worker

```python
# anomaly_worker.py
"""
AIOps Worker — runs every 5 minutes, checks for metric anomalies.
Deployed as a Kubernetes CronJob.
"""
import os
import json
import time
import requests
import statistics
from datetime import datetime, timedelta
from typing import List, Dict, Optional
import logging

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s %(levelname)s %(message)s'
)
log = logging.getLogger(__name__)

PROMETHEUS_URL = os.getenv("PROMETHEUS_URL", "http://monitoring-kube-prometheus-prometheus.monitoring:9090")
ALERTMANAGER_URL = os.getenv("ALERTMANAGER_URL", "http://monitoring-kube-prometheus-alertmanager.monitoring:9093")
LOOKBACK_HOURS = int(os.getenv("LOOKBACK_HOURS", "24"))   # Training window
ANOMALY_THRESHOLD = float(os.getenv("ANOMALY_THRESHOLD", "3.0"))  # Z-score threshold


def fetch_metric(query: str, duration: str = "1h") -> List[Dict]:
    """Fetch metric from Prometheus."""
    end = time.time()
    start = end - (LOOKBACK_HOURS * 3600)
    
    resp = requests.get(
        f"{PROMETHEUS_URL}/api/v1/query_range",
        params={"query": query, "start": start, "end": end, "step": "60"},
        timeout=30
    )
    resp.raise_for_status()
    
    data = resp.json()
    if data["status"] != "success":
        log.error(f"Prometheus query failed: {data}")
        return []
    
    results = []
    for series in data["data"]["result"]:
        results.append({
            "labels": series["metric"],
            "values": [(float(ts), float(val)) for ts, val in series["values"]]
        })
    return results


def zscore_anomaly(values: List[float], lookback_pct: float = 0.8) -> List[Dict]:
    """
    Detect anomalies using Z-score.
    Uses first 80% of data as baseline, flags anomalies in the last 20%.
    """
    if len(values) < 10:
        return []
    
    # Training window: first 80%
    split = int(len(values) * lookback_pct)
    baseline = values[:split]
    recent = values[split:]
    
    if not baseline:
        return []
    
    mean = statistics.mean(baseline)
    try:
        std = statistics.stdev(baseline)
    except statistics.StatisticsError:
        return []
    
    if std == 0:
        return []  # No variance — can't detect anomalies
    
    anomalies = []
    for i, val in enumerate(recent):
        zscore = abs(val - mean) / std
        if zscore > ANOMALY_THRESHOLD:
            anomalies.append({
                "value": val,
                "expected": mean,
                "zscore": zscore,
                "deviation_pct": abs(val - mean) / mean * 100 if mean != 0 else 0,
                "direction": "above" if val > mean else "below"
            })
    
    return anomalies


def check_metrics() -> List[Dict]:
    """Check key infrastructure metrics for anomalies."""
    alerts = []
    
    # Define metrics to check
    checks = [
        {
            "name": "cpu_usage",
            "query": "1 - avg(rate(node_cpu_seconds_total{mode='idle'}[5m])) by (node)",
            "description": "Node CPU utilization",
            "unit": "%",
            "scale": 100,
        },
        {
            "name": "memory_usage",
            "query": "1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes",
            "description": "Node memory utilization",
            "unit": "%",
            "scale": 100,
        },
        {
            "name": "pod_restarts",
            "query": "sum(rate(kube_pod_container_status_restarts_total[5m])) by (namespace)",
            "description": "Pod restart rate",
            "unit": "restarts/s",
            "scale": 1,
        },
        {
            "name": "http_error_rate",
            "query": """
                sum(rate(nginx_ingress_controller_requests{status=~"5.."}[5m]))
                /
                sum(rate(nginx_ingress_controller_requests[5m]))
            """,
            "description": "HTTP 5xx error rate",
            "unit": "%",
            "scale": 100,
        },
    ]
    
    for check in checks:
        log.info(f"Checking: {check['name']}")
        
        try:
            results = fetch_metric(check["query"])
        except Exception as e:
            log.warning(f"Failed to fetch {check['name']}: {e}")
            continue
        
        for series in results:
            values = [v[1] * check["scale"] for v in series["values"]]
            anomalies = zscore_anomaly(values)
            
            if anomalies:
                labels = series["labels"]
                # Take worst anomaly
                worst = max(anomalies, key=lambda x: x["zscore"])
                
                alert = {
                    "metric": check["name"],
                    "description": check["description"],
                    "labels": labels,
                    "value": round(worst["value"], 2),
                    "expected": round(worst["expected"], 2),
                    "zscore": round(worst["zscore"], 2),
                    "deviation_pct": round(worst["deviation_pct"], 1),
                    "direction": worst["direction"],
                    "unit": check["unit"],
                    "severity": (
                        "critical" if worst["zscore"] > 5 else
                        "high"     if worst["zscore"] > 4 else
                        "warning"
                    )
                }
                alerts.append(alert)
                log.warning(
                    f"ANOMALY: {check['name']} = {worst['value']:.1f}{check['unit']} "
                    f"(expected {worst['expected']:.1f}, Z={worst['zscore']:.1f})"
                )
    
    return alerts


def fire_alert(alert: Dict):
    """Send alert to Prometheus Alertmanager."""
    payload = [{
        "labels": {
            "alertname": f"AIOps_{alert['metric'].replace('_', '').title()}Anomaly",
            "severity": alert["severity"],
            "source": "aiops-anomaly-detector",
            **{k: str(v) for k, v in alert.get("labels", {}).items()}
        },
        "annotations": {
            "summary": f"AIOps anomaly detected: {alert['description']}",
            "description": (
                f"Metric {alert['metric']} is {alert['deviation_pct']:.0f}% "
                f"{alert['direction']} expected value "
                f"({alert['value']}{alert['unit']} vs expected {alert['expected']}{alert['unit']}). "
                f"Z-score: {alert['zscore']:.1f}"
            ),
        },
        "endsAt": (datetime.utcnow() + timedelta(minutes=10)).isoformat() + "Z",
    }]
    
    try:
        resp = requests.post(
            f"{ALERTMANAGER_URL}/api/v1/alerts",
            json=payload,
            timeout=10
        )
        resp.raise_for_status()
        log.info(f"Alert sent: {payload[0]['labels']['alertname']}")
    except Exception as e:
        log.error(f"Failed to send alert: {e}")


def main():
    log.info("=== AIOps Anomaly Detection Run ===")
    log.info(f"Prometheus: {PROMETHEUS_URL}")
    log.info(f"Lookback: {LOOKBACK_HOURS}h | Threshold: {ANOMALY_THRESHOLD} sigma")
    
    alerts = check_metrics()
    
    if not alerts:
        log.info("✅ No anomalies detected")
    else:
        log.warning(f"⚠️  {len(alerts)} anomalies detected!")
        for alert in alerts:
            fire_alert(alert)
    
    # Summary
    print(json.dumps({
        "timestamp": datetime.utcnow().isoformat(),
        "anomalies_found": len(alerts),
        "alerts": alerts
    }, indent=2))


if __name__ == "__main__":
    main()
```

---

## Part 3: Deploy as Kubernetes CronJob

```bash
# Build container image
cat > Dockerfile << 'EOF'
FROM python:3.12-slim
RUN pip install requests statistics
COPY anomaly_worker.py /app/worker.py
WORKDIR /app
CMD ["python", "worker.py"]
EOF

docker build -t aiops-worker:latest .
kind load docker-image aiops-worker:latest --name aiops-lab

# Deploy as CronJob
cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: aiops-config
  namespace: monitoring
data:
  PROMETHEUS_URL: "http://monitoring-kube-prometheus-prometheus.monitoring:9090"
  ALERTMANAGER_URL: "http://monitoring-kube-prometheus-alertmanager.monitoring:9093"
  LOOKBACK_HOURS: "24"
  ANOMALY_THRESHOLD: "3.0"
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: aiops-anomaly-detector
  namespace: monitoring
spec:
  schedule: "*/5 * * * *"          # Every 5 minutes
  concurrencyPolicy: Forbid          # Don't overlap runs
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: Never
          serviceAccountName: default
          containers:
          - name: worker
            image: aiops-worker:latest
            imagePullPolicy: Never
            envFrom:
            - configMapRef:
                name: aiops-config
            resources:
              requests:
                cpu: 100m
                memory: 256Mi
              limits:
                cpu: 500m
                memory: 512Mi
EOF

kubectl get cronjob -n monitoring

# Trigger manually for testing
kubectl create job test-aiops --from=cronjob/aiops-anomaly-detector -n monitoring
kubectl logs job/test-aiops -n monitoring -f
```

---

## Part 4: Generate Anomalous Load

```bash
# Create abnormal CPU load to trigger anomaly detection
kubectl run stress-test \
  --image=containerstack/stress:latest \
  --command -- stress --cpu 4 --timeout 300s &

# Wait for CronJob to run (or trigger manually)
kubectl create job anomaly-check --from=cronjob/aiops-anomaly-detector -n monitoring
kubectl logs job/anomaly-check -n monitoring

# Check if alerts were sent to Alertmanager
kubectl port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093 -n monitoring &
curl http://localhost:9093/api/v1/alerts | python3 -m json.tool
```

---

## Part 5: Add Intelligent Correlation

```python
# Add to anomaly_worker.py — correlate alerts from multiple sources
def correlate_alerts(alerts: List[Dict]) -> List[Dict]:
    """Group related anomalies into incidents."""
    if len(alerts) <= 1:
        return [{"incident": f"INC-{i+1}", "alerts": [a]} for i, a in enumerate(alerts)]
    
    incidents = []
    used = set()
    
    for i, alert_a in enumerate(alerts):
        if i in used:
            continue
        
        incident = {"incident": f"INC-{len(incidents)+1}", "alerts": [alert_a]}
        used.add(i)
        
        # Group alerts that fire within 5 minutes of each other
        for j, alert_b in enumerate(alerts):
            if j in used or j == i:
                continue
            # Same namespace or same node = likely related
            labels_a = alert_a.get("labels", {})
            labels_b = alert_b.get("labels", {})
            if (labels_a.get("namespace") == labels_b.get("namespace") or
                labels_a.get("node") == labels_b.get("node")):
                incident["alerts"].append(alert_b)
                used.add(j)
        
        incidents.append(incident)
    
    return incidents
```

---

## Cleanup

```bash
pkill -f "kubectl port-forward" 2>/dev/null || true
kubectl delete pod stress-test 2>/dev/null || true
kind delete cluster --name aiops-lab
cd ..
rm -rf aiops-lab
```

## What You Learned

- [x] AIOps anomaly detection using Z-score baseline comparison
- [x] Prometheus API for metric fetching
- [x] Alertmanager webhook integration
- [x] Kubernetes CronJob for periodic analysis
- [x] Alert correlation to group related anomalies into incidents
