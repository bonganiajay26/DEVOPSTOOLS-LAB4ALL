# Grafana — Dashboards, Visualization & Alerting

## Core Concepts

```
Data Source  →  Query  →  Panel  →  Dashboard  →  Alert
(Prometheus)   (PromQL)  (graph)    (collection)  (rule)
```

---

## Dashboard Panel Types

| Panel | Best For |
|-------|---------|
| Time series | Metrics over time (CPU, RPS, latency) |
| Stat | Single value with color threshold |
| Gauge | Percentage/ratio with fill |
| Bar chart | Comparison between categories |
| Table | Multiple metrics in rows/columns |
| Heatmap | Distribution over time |
| Logs | Log stream visualization |
| Traces | Distributed trace visualization |

---

## Variables for Dynamic Dashboards

```json
// Dashboard variable: $namespace
{
  "name": "namespace",
  "type": "query",
  "datasource": "Prometheus",
  "query": "label_values(kube_namespace_labels, namespace)",
  "includeAll": true,
  "multi": true
}

// Use in PromQL:
// rate(http_requests_total{namespace=~"$namespace"}[5m])
// The dashboard becomes interactive — user selects namespace
```

---

## Production Dashboard JSON Structure

```json
{
  "title": "Application Overview",
  "uid": "app-overview-v1",
  "tags": ["application", "production"],
  "time": { "from": "now-6h", "to": "now" },
  "refresh": "30s",
  "templating": {
    "list": [
      {
        "name": "datasource",
        "type": "datasource",
        "query": "prometheus"
      },
      {
        "name": "service",
        "type": "query",
        "datasource": "$datasource",
        "query": "label_values(up, job)"
      }
    ]
  },
  "panels": [
    {
      "title": "Request Rate",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
      "targets": [
        {
          "expr": "sum(rate(http_requests_total{job=~\"$service\"}[5m])) by (job)",
          "legendFormat": "{{job}}"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "reqps",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "green", "value": null },
              { "color": "yellow", "value": 500 },
              { "color": "red", "value": 1000 }
            ]
          }
        }
      }
    },
    {
      "title": "Error Rate (%)",
      "type": "stat",
      "gridPos": { "h": 4, "w": 6, "x": 12, "y": 0 },
      "targets": [
        {
          "expr": "sum(rate(http_requests_total{status=~\"5..\"}[5m])) / sum(rate(http_requests_total[5m])) * 100"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "green",  "value": null },
              { "color": "yellow", "value": 1    },
              { "color": "red",    "value": 5    }
            ]
          }
        }
      }
    }
  ]
}
```

---

## Alerting in Grafana (Unified Alerting)

```yaml
# Grafana alert rule (via provisioning)
apiVersion: 1
groups:
  - orgId: 1
    name: Production SLOs
    folder: Alerts
    interval: 1m
    rules:
    - uid: high-error-rate
      title: High Error Rate
      condition: C
      data:
      - refId: A
        queryType: ''
        relativeTimeRange:
          from: 300
          to: 0
        datasourceUid: prometheus
        model:
          expr: |
            sum(rate(http_requests_total{status=~"5.."}[5m]))
            /
            sum(rate(http_requests_total[5m]))
          instant: false
          intervalMs: 1000
          maxDataPoints: 43200
      - refId: C
        queryType: ''
        relativeTimeRange:
          from: 300
          to: 0
        datasourceUid: '-100'
        model:
          conditions:
          - evaluator:
              params: [0.01]
              type: gt
            operator:
              type: and
            query:
              params: [A]
            reducer:
              type: last
          type: classic_conditions
      noDataState: NoData
      execErrState: Error
      for: 5m
      annotations:
        summary: Error rate is {{ $values.A.Value | humanizePercentage }}
        runbook: https://wiki.company.com/runbooks/high-error-rate
      labels:
        severity: critical
        team: backend
```

---

## Grafana Provisioning (Infrastructure as Code)

```yaml
# Provision data source
# /etc/grafana/provisioning/datasources/prometheus.yml
apiVersion: 1
datasources:
- name: Prometheus
  type: prometheus
  uid: prometheus
  url: http://prometheus:9090
  isDefault: true
  editable: false
  jsonData:
    httpMethod: POST
    prometheusType: Prometheus
    prometheusVersion: 2.48.0

- name: Loki
  type: loki
  uid: loki
  url: http://loki:3100
  jsonData:
    derivedFields:
    - name: TraceID
      matcherRegex: '"traceId":"(\w+)"'
      url: '$${__value.raw}'
      datasourceUid: tempo

# Provision dashboard folder
# /etc/grafana/provisioning/dashboards/dashboards.yml
apiVersion: 1
providers:
- name: default
  folder: Production
  type: file
  disableDeletion: false
  updateIntervalSeconds: 30
  allowUiUpdates: true
  options:
    path: /var/lib/grafana/dashboards
```

---

## Key Grafana PromQL Patterns

```promql
# ── Availability ───────────────────────────────────────────────
# Current uptime %
avg_over_time(up{job="myapp"}[30d]) * 100

# ── Latency ────────────────────────────────────────────────────
# p50/p95/p99 latency
histogram_quantile(0.50, rate(http_duration_seconds_bucket[5m]))
histogram_quantile(0.95, rate(http_duration_seconds_bucket[5m]))
histogram_quantile(0.99, rate(http_duration_seconds_bucket[5m]))

# ── Saturation ─────────────────────────────────────────────────
# CPU usage per pod
sum(rate(container_cpu_usage_seconds_total{namespace="production"}[5m]))
  by (pod) * 100

# Memory usage % of limit
container_memory_usage_bytes / container_spec_memory_limit_bytes * 100

# ── Traffic ────────────────────────────────────────────────────
# Requests per second by status
sum(rate(http_requests_total[5m])) by (status)

# ── Error rate by endpoint ─────────────────────────────────────
topk(10,
  sum(rate(http_requests_total{status=~"5.."}[5m])) by (handler)
  /
  sum(rate(http_requests_total[5m])) by (handler)
)
```
