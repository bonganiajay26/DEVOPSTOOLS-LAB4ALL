# Lab 01: Implement SLOs with Prometheus

**Difficulty**: Advanced | **Time**: 60 minutes  
**Goal**: Define SLOs, implement error budget tracking, and set up burn-rate alerts.

---

## Setup

```bash
# Requires: kube-prometheus-stack running (see prometheus-grafana lab)
kubectl get pods -n monitoring | grep prometheus
```

---

## Part 1: Deploy a Sample App with SLI Metrics

```bash
# Deploy a Flask app that exposes /metrics
cat << 'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: slo-demo-app
  namespace: default
spec:
  replicas: 3
  selector:
    matchLabels:
      app: slo-demo-app
  template:
    metadata:
      labels:
        app: slo-demo-app
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
    spec:
      containers:
      - name: app
        image: nginx:alpine
        ports:
        - containerPort: 8080
          name: http
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
---
apiVersion: v1
kind: Service
metadata:
  name: slo-demo-app
  labels:
    app: slo-demo-app
spec:
  selector:
    app: slo-demo-app
  ports:
  - name: http
    port: 8080
    targetPort: 8080
EOF
```

---

## Part 2: Define SLO Recording Rules

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: slo-demo-rules
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
  - name: slo-recording
    interval: 1m
    rules:
    # Availability: good requests / total requests
    - record: job:slo_demo:availability_rate5m
      expr: |
        1 - (
          sum(rate(nginx_http_requests_total{status=~"5.."}[5m]) or vector(0))
          /
          sum(rate(nginx_http_requests_total[5m]) or vector(1))
        )

    # Error budget remaining (30-day window)
    # SLO target: 99.9% → allowed error rate: 0.1%
    - record: job:slo_demo:error_budget_pct
      expr: |
        (0.001 - (
          sum(rate(nginx_http_requests_total{status=~"5.."}[30d]) or vector(0))
          /
          sum(rate(nginx_http_requests_total[30d]) or vector(1))
        )) / 0.001 * 100

  - name: slo-alerts
    rules:
    - alert: SLODemoBurning
      expr: |
        (
          sum(rate(nginx_http_requests_total{status=~"5.."}[1h]) or vector(0))
          /
          sum(rate(nginx_http_requests_total[1h]) or vector(1))
        ) > (14.4 * 0.001)
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "SLO Demo App error budget burning too fast"
EOF
```

---

## Part 3: Visualize in Grafana

```bash
# Create an SLO dashboard
cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: slo-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  slo-dashboard.json: |
    {
      "title": "SLO Dashboard",
      "uid": "slo-demo",
      "refresh": "30s",
      "panels": [
        {
          "id": 1,
          "title": "Error Budget Remaining (%)",
          "type": "gauge",
          "gridPos": {"h": 8, "w": 8, "x": 0, "y": 0},
          "targets": [{
            "expr": "job:slo_demo:error_budget_pct",
            "instant": true
          }],
          "fieldConfig": {
            "defaults": {
              "unit": "percent",
              "min": 0, "max": 100,
              "thresholds": {
                "steps": [
                  {"color": "red", "value": null},
                  {"color": "yellow", "value": 25},
                  {"color": "green", "value": 50}
                ]
              }
            }
          }
        },
        {
          "id": 2,
          "title": "Availability Rate",
          "type": "timeseries",
          "gridPos": {"h": 8, "w": 16, "x": 8, "y": 0},
          "targets": [{
            "expr": "job:slo_demo:availability_rate5m * 100",
            "legendFormat": "Availability %"
          }],
          "fieldConfig": {
            "defaults": {
              "unit": "percent",
              "custom": {
                "fillOpacity": 10
              }
            },
            "overrides": [{
              "matcher": {"id": "byName", "options": "Availability %"},
              "properties": [{
                "id": "thresholds",
                "value": {
                  "mode": "absolute",
                  "steps": [
                    {"color": "red", "value": null},
                    {"color": "yellow", "value": 99.0},
                    {"color": "green", "value": 99.9}
                  ]
                }
              }]
            }]
          }
        }
      ]
    }
EOF

# View at Grafana → Dashboards → SLO Dashboard
```

---

## Part 4: Simulate SLO Violation

```bash
# Generate error traffic to burn the error budget
kubectl run load-gen --image=curlimages/curl --rm -it -- sh

# Inside the container:
# Generate 10% error rate (hit non-existent endpoint)
while true; do
  curl -s slo-demo-app:8080/ > /dev/null       # 200 OK
  curl -s slo-demo-app:8080/ > /dev/null       # 200 OK
  curl -s slo-demo-app:8080/ > /dev/null       # 200 OK
  curl -s slo-demo-app:8080/ > /dev/null       # 200 OK
  curl -s slo-demo-app:8080/ > /dev/null       # 200 OK
  curl -s slo-demo-app:8080/ > /dev/null       # 200 OK
  curl -s slo-demo-app:8080/ > /dev/null       # 200 OK
  curl -s slo-demo-app:8080/ > /dev/null       # 200 OK
  curl -s slo-demo-app:8080/ > /dev/null       # 200 OK
  curl -s slo-demo-app:8080/this-errors > /dev/null  # 404 (counts as error)
  sleep 0.1
done
# Ctrl+C when done

# Watch error budget in Grafana
# Should see error budget dropping
# Alert should fire after 5 minutes
```

---

## Part 5: Error Budget Policy Exercise

```
Given:
  Monthly error budget: 43.2 minutes (99.9% SLO)
  Incident A: 15-minute outage (35% budget)
  Incident B: 10-minute partial degradation (23% budget)
  Remaining after incidents: 42% (18.1 minutes)

Questions:
1. Can we deploy a risky migration (estimated 5 min downtime risk)?
   Answer: 18.1 min remaining > 5 min risk → YES (with monitoring)

2. A team wants to run load testing on production. Allowed?
   Answer: 42% remaining — should wait, load testing too risky this month

3. Developers want to ship 5 features this week. Allowed?
   Answer: Yes, but use canary deployments with automatic rollback
```

---

## Cleanup

```bash
kubectl delete deployment slo-demo-app
kubectl delete service slo-demo-app
kubectl delete prometheusrule slo-demo-rules -n monitoring
kubectl delete configmap slo-dashboard -n monitoring
```

## What You Learned

- [x] Defining SLIs (metrics that measure SLO compliance)
- [x] Recording rules for pre-computed SLO metrics
- [x] Multi-window burn rate alerting
- [x] Error budget visualization in Grafana
- [x] Error budget policy decision making
