# Prometheus Deep Dive

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                 Prometheus Server                         │
│                                                          │
│  ┌─────────────┐   ┌─────────────┐   ┌───────────────┐  │
│  │  Retrieval  │   │    TSDB     │   │  HTTP Server  │  │
│  │  (scraper)  │   │  (storage)  │   │  (PromQL API) │  │
│  └──────┬──────┘   └─────────────┘   └───────────────┘  │
│         │                                    ↑           │
│  ┌──────▼──────┐   ┌─────────────┐           │           │
│  │  Service    │   │   Rules     │           │           │
│  │  Discovery  │   │  Evaluator  │           │           │
│  └─────────────┘   └──────┬──────┘           │           │
└──────────────────────────┼────────────────────┘
                            │ alerts
                    ┌───────▼────────┐
                    │  Alertmanager  │──► Slack/PagerDuty
                    └────────────────┘
↑ scrapes
┌─────────────────────────────────────┐
│  Targets (expose /metrics endpoint) │
│  node-exporter  myapp  redis-exporter│
└─────────────────────────────────────┘
```

---

## Metric Types

```python
# Counter — monotonically increasing (resets on restart)
# Use for: requests, errors, bytes processed
http_requests_total{method="GET", status="200"} 15234

# Gauge — current value (can go up or down)
# Use for: current connections, memory usage, queue depth
http_active_connections 42
memory_usage_bytes 536870912

# Histogram — distribution of values (buckets + sum + count)
# Use for: request latency, response sizes
http_request_duration_seconds_bucket{le="0.1"} 1234
http_request_duration_seconds_bucket{le="0.5"} 5678
http_request_duration_seconds_bucket{le="+Inf"} 9012
http_request_duration_seconds_sum 1234.5
http_request_duration_seconds_count 9012

# Summary — pre-calculated quantiles (can't aggregate across instances)
# Use only when you need exact quantiles, prefer Histogram otherwise
http_request_duration_seconds{quantile="0.99"} 0.85
```

---

## PromQL — The Query Language

### Selectors

```promql
# All time series for metric
http_requests_total

# Filter by labels
http_requests_total{job="api", status="200"}
http_requests_total{status=~"5.."}        # Regex: 5xx errors
http_requests_total{status!~"2.."}        # Not 2xx
http_requests_total{pod=~"api-.*"}        # Pods starting with api-
```

### Functions

```promql
# rate() — per-second rate of change over time window
# Use for Counters (handles resets)
rate(http_requests_total[5m])

# irate() — instant rate (last 2 samples) — spiky, good for alerts
irate(http_requests_total[5m])

# increase() — total increase over range (rate × duration)
increase(http_requests_total[1h])    # Requests in last hour

# delta() — difference between first and last (use for Gauges)
delta(memory_usage_bytes[1h])

# quantile() — histogram percentile
histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))

# avg_over_time() / max_over_time()
avg_over_time(http_active_connections[10m])

# predict_linear() — extrapolation
predict_linear(disk_free_bytes[1h], 4*3600)  # Disk free in 4 hours
```

### Aggregation

```promql
# sum() — total across all instances
sum(rate(http_requests_total[5m]))

# by() — keep specified labels
sum(rate(http_requests_total[5m])) by (service)

# without() — drop specified labels
sum(rate(http_requests_total[5m])) without (pod, instance)

# topk() — top N time series
topk(5, rate(http_requests_total[5m]))

# CPU usage per pod (practical example)
sum(
  rate(container_cpu_usage_seconds_total{namespace="production"}[5m])
) by (pod)
```

### Real-World Queries

```promql
# Error rate as percentage
(
  sum(rate(http_requests_total{status=~"5.."}[5m]))
  /
  sum(rate(http_requests_total[5m]))
) * 100

# p99 latency
histogram_quantile(0.99,
  sum(rate(http_request_duration_seconds_bucket[5m])) by (le)
)

# Pod memory usage percentage
(
  container_memory_usage_bytes{namespace="production"}
  /
  container_spec_memory_limit_bytes{namespace="production"}
) * 100

# Node disk will fill in < 24h
predict_linear(
  node_filesystem_avail_bytes{mountpoint="/"}[1h], 24*3600
) < 0

# Service availability (% time with at least 1 replica)
avg_over_time(
  (kube_deployment_status_replicas_available{deployment="api"} > 0)[30d:5m]
) * 100

# Top 10 pods by CPU
topk(10,
  sum(rate(container_cpu_usage_seconds_total{namespace="production"}[5m]))
  by (pod)
)
```

---

## Alert Rules

```yaml
# prometheus-rules.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: production-alerts
  labels:
    release: kube-prometheus-stack
spec:
  groups:
  - name: availability
    rules:
    # SLO: 99.9% availability
    - alert: ServiceDown
      expr: |
        (
          1 - avg_over_time(
            (up{job="api-service"})[5m:]
          )
        ) > 0.001
      for: 2m
      labels:
        severity: critical
        slo: availability
      annotations:
        summary: "API service availability < 99.9%"
        runbook: "https://wiki/runbooks/service-down"

  - name: latency
    rules:
    - alert: HighLatencyP99
      expr: |
        histogram_quantile(0.99,
          sum(rate(http_request_duration_seconds_bucket{job="api"}[5m])) by (le)
        ) > 1
      for: 5m
      labels:
        severity: warning
      annotations:
        description: "p99 latency is {{ $value | humanizeDuration }}"

  - name: infrastructure
    rules:
    - alert: HighMemoryUsage
      expr: |
        (
          node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes
        ) / node_memory_MemTotal_bytes > 0.9
      for: 10m
      labels:
        severity: warning
      annotations:
        summary: "Node {{ $labels.instance }} memory > 90%"

    - alert: DiskWillFillIn24Hours
      expr: |
        predict_linear(node_filesystem_avail_bytes{mountpoint="/"}[1h], 24*3600) < 0
      for: 1h
      labels:
        severity: warning
      annotations:
        summary: "Disk on {{ $labels.instance }} will fill in 24h"

  - name: recording_rules          # Pre-compute expensive queries
    rules:
    - record: job:http_requests_total:rate5m
      expr: sum(rate(http_requests_total[5m])) by (job)
    - record: job:http_errors_total:rate5m
      expr: sum(rate(http_requests_total{status=~"5.."}[5m])) by (job)
```

---

## prometheus.yml (Scrape Config)

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    cluster: production
    region: us-east-1

rule_files:
- /etc/prometheus/rules/*.yml

scrape_configs:
# Kubernetes API server
- job_name: kubernetes-apiservers
  kubernetes_sd_configs:
  - role: endpoints
  scheme: https
  tls_config:
    ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    insecure_skip_verify: true
  bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
  relabel_configs:
  - source_labels: [__meta_kubernetes_namespace, __meta_kubernetes_service_name, __meta_kubernetes_endpoint_port_name]
    action: keep
    regex: default;kubernetes;https

# Pod metrics (auto-discover pods with annotations)
- job_name: kubernetes-pods
  kubernetes_sd_configs:
  - role: pod
  relabel_configs:
  - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
    action: keep
    regex: "true"
  - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
    action: replace
    target_label: __metrics_path__
    regex: (.+)
  - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_port]
    action: replace
    target_label: __address__
    regex: (.+)
    replacement: ${1}
  - source_labels: [__meta_kubernetes_namespace]
    target_label: namespace
  - source_labels: [__meta_kubernetes_pod_name]
    target_label: pod
```
