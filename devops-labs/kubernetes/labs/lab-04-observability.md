# Lab 04: Full Observability — Prometheus, Grafana & Alerting

**Difficulty**: Advanced | **Time**: 60 minutes  
**Goal**: Install kube-prometheus-stack, instrument an app, create dashboards, configure alerts.

---

## What Gets Deployed

```
kube-prometheus-stack (Helm chart) installs:
├── Prometheus          — metrics collection & alerting
├── Grafana             — dashboards & visualization
├── Alertmanager        — alert routing (Slack/PagerDuty)
├── node-exporter       — hardware & OS metrics (DaemonSet)
├── kube-state-metrics  — K8s object state metrics
└── Prometheus Operator — manages PrometheusRule/ServiceMonitor CRDs
```

---

## Part 1: Install kube-prometheus-stack

```bash
# Add Helm repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Create namespace
kubectl create namespace monitoring

# Install with custom values
cat > prometheus-values.yaml << 'EOF'
grafana:
  adminPassword: "admin123"           # Change in production
  persistence:
    enabled: true
    size: 5Gi
  dashboardProviders:
    dashboardproviders.yaml:
      apiVersion: 1
      providers:
      - name: default
        folder: ''
        type: file
        disableDeletion: false
        options:
          path: /var/lib/grafana/dashboards/default

prometheus:
  prometheusSpec:
    retention: 15d
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 20Gi
    # Watch all namespaces for ServiceMonitors
    serviceMonitorNamespaceSelector: {}
    serviceMonitorSelector: {}
    podMonitorNamespaceSelector: {}
    podMonitorSelector: {}
    ruleNamespaceSelector: {}

alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 2Gi
EOF

helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values prometheus-values.yaml \
  --version 58.0.0

# Wait for all pods
kubectl rollout status deployment/kube-prometheus-stack-grafana -n monitoring
kubectl rollout status deployment/kube-prometheus-stack-kube-state-metrics -n monitoring

# Verify
kubectl get pods -n monitoring
```

---

## Part 2: Access Dashboards

```bash
# Grafana (admin / admin123)
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring &
# Open: http://localhost:3000

# Prometheus UI
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring &
# Open: http://localhost:9090

# Alertmanager
kubectl port-forward svc/kube-prometheus-stack-alertmanager 9093:9093 -n monitoring &
# Open: http://localhost:9093
```

### Explore in Prometheus UI:
```promql
# Node CPU usage
1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) by (node)

# Memory usage %
(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100

# Pod restarts in last 1h
increase(kube_pod_container_status_restarts_total[1h]) > 0

# HTTP error rate
rate(http_requests_total{status=~"5.."}[5m]) / rate(http_requests_total[5m])
```

---

## Part 3: Instrument Your Application

### Add Prometheus metrics to your app

```python
# Add to src/app.py
from prometheus_client import Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST
import time

# Define metrics
REQUEST_COUNT = Counter('http_requests_total',
                        'Total HTTP requests',
                        ['method', 'endpoint', 'status'])

REQUEST_LATENCY = Histogram('http_request_duration_seconds',
                             'HTTP request latency',
                             ['method', 'endpoint'],
                             buckets=[.005, .01, .025, .05, .1, .25, .5, 1, 2.5, 5])

ACTIVE_REQUESTS = Gauge('http_active_requests', 'Active HTTP requests')

# Middleware to track metrics
@app.before_request
def before_request():
    ACTIVE_REQUESTS.inc()
    request.start_time = time.time()

@app.after_request
def after_request(response):
    ACTIVE_REQUESTS.dec()
    latency = time.time() - request.start_time
    REQUEST_LATENCY.labels(
        method=request.method,
        endpoint=request.path
    ).observe(latency)
    REQUEST_COUNT.labels(
        method=request.method,
        endpoint=request.path,
        status=response.status_code
    ).inc()
    return response

# Metrics endpoint
@app.route("/metrics")
def metrics():
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}
```

### ServiceMonitor — tell Prometheus to scrape your app

```yaml
# k8s/service-monitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: my-api-monitor
  namespace: production
  labels:
    app: my-api
    release: kube-prometheus-stack    # Must match Prometheus operator's selector
spec:
  selector:
    matchLabels:
      app: my-api
  endpoints:
  - port: http                        # Port name in Service spec
    path: /metrics
    interval: 15s
    scrapeTimeout: 10s
  namespaceSelector:
    matchNames:
    - production
```

```bash
kubectl apply -f k8s/service-monitor.yaml

# Verify Prometheus discovered the target
# Prometheus UI → Status → Targets → look for my-api
```

---

## Part 4: PrometheusRule — Alerting Rules

```yaml
# k8s/alerts.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: my-api-alerts
  namespace: production
  labels:
    release: kube-prometheus-stack
spec:
  groups:
  - name: my-api.availability
    interval: 30s
    rules:
    # Alert if error rate > 1% for 5 minutes
    - alert: HighErrorRate
      expr: |
        (
          rate(http_requests_total{app="my-api", status=~"5.."}[5m])
          /
          rate(http_requests_total{app="my-api"}[5m])
        ) > 0.01
      for: 5m
      labels:
        severity: critical
        team: backend
      annotations:
        summary: "High error rate on my-api"
        description: "Error rate is {{ $value | humanizePercentage }} for the last 5 minutes"
        runbook: "https://wiki.company.com/runbooks/my-api-high-errors"

    # Alert if p99 latency > 1 second
    - alert: HighLatencyP99
      expr: |
        histogram_quantile(0.99,
          rate(http_request_duration_seconds_bucket{app="my-api"}[5m])
        ) > 1
      for: 5m
      labels:
        severity: warning
        team: backend
      annotations:
        summary: "High p99 latency on my-api"
        description: "p99 latency is {{ $value | humanizeDuration }}"

    # Alert if pod count drops below minimum
    - alert: PodCountTooLow
      expr: |
        kube_deployment_status_replicas_available{
          deployment="my-api", namespace="production"
        } < 2
      for: 2m
      labels:
        severity: critical
      annotations:
        summary: "my-api has fewer than 2 running pods"
        description: "Only {{ $value }} pods are available"
```

```bash
kubectl apply -f k8s/alerts.yaml

# Verify rules loaded
# Prometheus UI → Alerts → look for my-api alerts
```

---

## Part 5: Alertmanager — Route to Slack

```yaml
# Update alertmanager config
cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-kube-prometheus-stack-alertmanager
  namespace: monitoring
stringData:
  alertmanager.yaml: |
    global:
      resolve_timeout: 5m
      slack_api_url: 'https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK'

    route:
      group_by: ['alertname', 'namespace']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h
      receiver: 'default'
      routes:
      - match:
          severity: critical
        receiver: 'pagerduty-critical'
      - match:
          severity: warning
        receiver: 'slack-warnings'

    receivers:
    - name: 'default'
      slack_configs:
      - channel: '#alerts'
        title: '{{ .GroupLabels.alertname }}'
        text: '{{ range .Alerts }}{{ .Annotations.description }}{{ end }}'

    - name: 'slack-warnings'
      slack_configs:
      - channel: '#alerts-warning'
        send_resolved: true
        title: '⚠️ {{ .GroupLabels.alertname }}'
        text: '{{ range .Alerts }}{{ .Annotations.description }}{{ end }}'

    - name: 'pagerduty-critical'
      pagerduty_configs:
      - routing_key: 'YOUR_PAGERDUTY_KEY'
        description: '{{ .GroupLabels.alertname }}: {{ .CommonAnnotations.summary }}'
EOF
```

---

## Part 6: Import Grafana Dashboard

```bash
# Import popular dashboard IDs via Grafana UI:
# Dashboards → Import → Enter ID

# Kubernetes Cluster Overview: 6417
# Node Exporter Full: 1860
# Kubernetes Deployment metrics: 8588
# NGINX Ingress Controller: 9614

# Or create dashboard programmatically
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-api-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"           # Grafana sidecar auto-imports this
data:
  my-api-dashboard.json: |
    {
      "title": "My API Dashboard",
      "panels": [
        {
          "title": "Request Rate",
          "type": "graph",
          "targets": [{
            "expr": "rate(http_requests_total{app='my-api'}[5m])"
          }]
        }
      ]
    }
EOF
```

---

## Cleanup

```bash
helm uninstall kube-prometheus-stack -n monitoring
kubectl delete namespace monitoring
```

## What You Learned

- [x] Installing kube-prometheus-stack via Helm
- [x] Instrumenting a Python app with prometheus_client
- [x] ServiceMonitor for automatic scraping discovery
- [x] PrometheusRule for custom alerting
- [x] Alertmanager routing to Slack and PagerDuty
- [x] Grafana dashboard importing

## Next Lab

→ [Lab 05: RBAC & Security Hardening](lab-05-security.md)
