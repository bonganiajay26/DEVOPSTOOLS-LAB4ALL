# Prometheus & Grafana Interview Questions

## Q1. What is the difference between rate() and irate()?

```promql
# rate() — average rate over the entire range (smooth)
# Best for: dashboards, alerts (less noisy)
rate(http_requests_total[5m])    # Avg req/s over 5 minutes

# irate() — instant rate based on last 2 data points (spiky)
# Best for: detecting short spikes
irate(http_requests_total[5m])   # Current req/s (uses last 2 samples)

# When to use which:
# Alerts: rate() — avoids false alarms from single spiky second
# Debug spike: irate() — see exact moment spike occurred
# Graph trends: rate() with larger window (1h, 6h)
```

---

## Q2. Explain Prometheus's pull model. What are the trade-offs vs push?

**Pull**: Prometheus scrapes targets on a schedule
- ✅ Prometheus controls what gets collected (health visible: is target up?)
- ✅ No need for agents to know where Prometheus is
- ❌ Hard for short-lived jobs (batch jobs may finish before next scrape)
- Solution: Pushgateway for batch jobs

**Push**: Agents send metrics to server (StatsD, InfluxDB)
- ✅ Works for ephemeral jobs
- ❌ Can't detect dead agents (fire-and-forget)

```yaml
# Pushgateway for batch jobs
- job_name: batch-jobs
  honor_labels: true
  static_configs:
  - targets: ['pushgateway:9091']
```

```python
# Push from batch job
from prometheus_client import CollectorRegistry, Gauge, push_to_gateway
registry = CollectorRegistry()
g = Gauge('job_last_success_unixtime', 'Last success', registry=registry)
g.set_to_current_time()
push_to_gateway('pushgateway:9091', job='batch-backup', registry=registry)
```

---

## Q3. How do you implement SLOs with Prometheus?

```promql
# SLO: 99.9% of requests succeed (error rate < 0.1%)

# Error rate (5m window for fast burn alert)
(
  sum(rate(http_requests_total{status=~"5.."}[5m]))
  /
  sum(rate(http_requests_total[5m]))
) > 0.001    # Alert if > 0.1% errors

# Error budget burn rate (1h window)
# If burning budget 14x faster than allowed → will exhaust budget in 5 days
(
  sum(rate(http_requests_total{status=~"5.."}[1h]))
  /
  sum(rate(http_requests_total[1h]))
) / 0.001 > 14   # 14x burn rate

# Availability over 30 days (for SLO tracking)
sum_over_time(
  (up{job="api"} == 1)[30d:1m]
) / (30 * 24 * 60) * 100
```

---

## Q4. What is a recording rule and why use it?

```yaml
# Recording rules pre-compute expensive queries
# Results stored as new time series, queryable like any metric
groups:
- name: precomputed
  interval: 1m
  rules:
  - record: instance:node_cpu_utilization:avg1m
    expr: |
      1 - avg without (cpu, mode)(
        rate(node_cpu_seconds_total{mode="idle"}[1m])
      )

  - record: job:http_error_rate:ratio5m
    expr: |
      sum(rate(http_requests_total{status=~"5.."}[5m])) by (job)
      /
      sum(rate(http_requests_total[5m])) by (job)

# Benefits:
# 1. Dashboard load time: query precomputed result vs raw data
# 2. Alert query evaluation: faster, less CPU
# 3. Aggregation: roll up high-cardinality metrics
```

---

## Q5. How do you handle high cardinality in Prometheus?

High cardinality = too many unique label value combinations → memory issues, slow queries.

```promql
# BAD: user_id label creates millions of time series
http_requests_total{user_id="12345678", path="/api/users"} 5
# → 10M users × 100 paths = 1 billion time series!

# GOOD: don't use high-cardinality values as labels
http_requests_total{path="/api/users"} 5  # Aggregate by path, not user

# Rules:
# ❌ Labels: user_id, email, trace_id, session_id, UUID, IP address
# ✅ Labels: service, endpoint, status, method, region, environment
```

```yaml
# Drop high-cardinality labels at scrape time (relabeling)
- job_name: myapp
  relabel_configs:
  - source_labels: [__name__]
    regex: "debug_.*"           # Drop debug metrics entirely
    action: drop
  metric_relabel_configs:
  - source_labels: [user_id]
    target_label: user_id
    replacement: "REMOVED"      # Replace with constant
```

---

## Q6. Explain Alertmanager routing and deduplication.

```yaml
# Alertmanager deduplicates: same alert from Prometheus fires every eval interval
# But Alertmanager only sends notification once (until resolved or repeat_interval)

route:
  group_by: [alertname, cluster, namespace]  # Group similar alerts together
  group_wait: 30s        # Wait 30s to collect more alerts in group before notifying
  group_interval: 5m     # Wait 5m before sending new notification for same group
  repeat_interval: 4h    # Resend alert if still firing after 4h
  receiver: default
  routes:
  - match:
      severity: critical
    receiver: pagerduty
    continue: false        # Don't fall through to next route
  - match_re:
      alertname: "(DiskWillFill|HighMemory)"
    receiver: slack-infra

receivers:
- name: pagerduty
  pagerduty_configs:
  - routing_key: XXXX
    severity: '{{ .CommonLabels.severity }}'

- name: slack-infra
  slack_configs:
  - api_url: https://hooks.slack.com/services/XXX
    channel: '#infra-alerts'
    title: '{{ .GroupLabels.alertname }}'
    text: '{{ range .Alerts }}{{ .Annotations.description }}{{ end }}'
    send_resolved: true
```

---

## Q7. How do you federate Prometheus across multiple clusters?

```yaml
# Global Prometheus scrapes summary from per-cluster Prometheus
scrape_configs:
- job_name: federate
  scrape_interval: 15s
  honor_labels: true
  metrics_path: /federate
  params:
    match[]:
    - '{job="kubernetes-pods"}'
    - '{__name__=~"job:.*"}'   # Only recording rules (not raw metrics)
  static_configs:
  - targets:
    - prometheus.cluster-1:9090
    - prometheus.cluster-2:9090
```

**Better approach**: Use **Thanos** or **Cortex** for true long-term, multi-cluster storage.

---

## Q8. What is Grafana's data source, and which ones matter most for DevOps?

```
Prometheus    → Metrics (the primary one for K8s)
Loki          → Logs (log aggregation, pairs with Prometheus)
Tempo         → Traces (distributed tracing)
Elasticsearch → Logs + full-text search
InfluxDB      → Metrics (time series database)
CloudWatch    → AWS metrics
Datadog       → Managed observability
MySQL/Postgres → Business metrics, custom dashboards
```

**Correlation**: Click on a spike in Prometheus → jump to Loki logs at that timestamp → see Tempo trace for that request. This is the Grafana "LGTM stack" (Loki, Grafana, Tempo, Mimir).

---

## Q9. How do you set up Grafana dashboards as code?

```bash
# Method 1: JSON export/import (manual)
# Dashboard → Share → Export JSON

# Method 2: dashboard ConfigMaps (Grafana sidecar auto-imports)
apiVersion: v1
kind: ConfigMap
metadata:
  name: api-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"        # Sidecar watches for this label
data:
  api-dashboard.json: |
    { ... dashboard JSON ... }

# Method 3: Grafonnet (Jsonnet-based)
local grafana = import 'grafonnet/grafana.libsonnet';
grafana.dashboard.new('API Dashboard')
  .addPanel(grafana.graphPanel.new('Request Rate')
    .addTarget(grafana.prometheus.target('rate(http_requests_total[5m])')))

# Method 4: Terraform Grafana provider
resource "grafana_dashboard" "api" {
  config_json = file("dashboards/api.json")
  folder      = grafana_folder.production.id
}
```

---

## Q10. Container is using too much memory according to Prometheus. How do you investigate?

```promql
# 1. Find memory usage over time
container_memory_usage_bytes{pod="api-abc123", container="api"}

# 2. Compare to limits
container_memory_usage_bytes{pod="api-abc123"}
/
container_spec_memory_limit_bytes{pod="api-abc123"}

# 3. Memory over time — is it growing? (leak)
# If graph shows steady upward trend → memory leak
increase(container_memory_usage_bytes{container="api"}[1h])

# 4. Check if OOMKilled
container_oom_events_total{container="api"}

# 5. Working set vs RSS
container_memory_working_set_bytes  # What K8s uses for OOM decisions
container_memory_rss                 # Actual resident memory

# Action:
# If working_set > 80% of limit → increase limit or fix memory leak
# If growing 5% per hour → investigate memory leak with pprof/memory profiler
```

---

## Q11. How do you set up alerting for a new service from scratch?

```
Step 1: Define SLOs first (what matters to users)
  - Availability: 99.9%
  - Latency: p99 < 500ms
  - Error rate: < 0.1%

Step 2: Instrument the service (expose /metrics)

Step 3: Create ServiceMonitor (K8s) or add to prometheus.yml

Step 4: Verify scraping (Prometheus UI → Targets)

Step 5: Write alert rules (PrometheusRule)
  - Alert for each SLO violation
  - Alert for dependencies (DB down, queue full)

Step 6: Configure Alertmanager routing

Step 7: Create runbook for each alert
  - What does it mean?
  - Immediate actions (scale, restart, rollback)
  - Root cause investigation steps

Step 8: Test alerts
  - kubectl exec - simulate failures
  - Verify Alertmanager receives and routes
```

---

## Q12. What is the difference between Prometheus and Datadog?

| | Prometheus | Datadog |
|-|-----------|---------|
| Type | Open source, self-hosted | SaaS, managed |
| Cost | Free (infra cost only) | $15-30/host/month |
| Setup | Requires K8s expertise | Agent install, quick start |
| Query | PromQL (learning curve) | Metrics Explorer (easy) |
| APM | Needs Jaeger/Tempo | Built-in distributed tracing |
| Logs | Needs Loki | Built-in log management |
| Retention | You control | 15 months max |
| At scale | Thanos/Cortex | Managed scaling |

**When Prometheus**: K8s-native, cost-sensitive, already have expertise, need customization.
**When Datadog**: Mixed infrastructure, fast time-to-value, APM is critical, compliance features.

---

## Q13. What is Thanos and when do you need it?

Thanos extends Prometheus with:
- **Long-term storage**: Upload blocks to S3/GCS (Prometheus default = 15 days)
- **Unlimited retention**: Query years of data
- **Multi-cluster querying**: Single query across 10 Prometheus servers
- **Global view**: One Grafana dashboard showing all clusters
- **High availability**: Multiple Prometheus replicas, deduplicated

```
Per-cluster:
  Prometheus → Thanos Sidecar → S3 bucket

Global:
  Thanos Querier → queries all sidecars + S3
  Thanos Compactor → compacts old blocks in S3
  Thanos Store Gateway → serves queries from S3
  Thanos Ruler → evaluates rules globally
```

---

## Q14. A critical alert fires at 3 AM. Walk me through your response.

```
1. ACKNOWLEDGE (stop alert noise)
   - Acknowledge in PagerDuty/Opsgenie

2. ASSESS IMPACT (< 2 min)
   - Is the service completely down or degraded?
   - How many users affected?
   - Revenue impact?

3. CHECK DASHBOARD (< 5 min)
   - Grafana: when did it start? Is it getting worse?
   - What changed recently? (deployments, config changes)

4. QUICK WINS (< 10 min)
   - Recent deployment? → kubectl rollout undo
   - OOM? → kubectl delete pod (force restart)
   - Single pod? → kubectl delete pod (self-healing)

5. COMMUNICATE
   - Update status page
   - Ping team in Slack with current situation

6. ROOT CAUSE (ongoing)
   - If quick fix worked → track down actual cause in business hours
   - If not → escalate + continue investigation

7. POST-INCIDENT (next day)
   - Write post-mortem
   - Add monitoring for the specific failure
   - Fix root cause
   - Update runbook
```

---

## Q15. How do you reduce alert fatigue?

```yaml
# 1. Add 'for' duration — only alert if sustained
- alert: HighErrorRate
  expr: error_rate > 0.01
  for: 5m                          # Must be elevated for 5 min, not just one second

# 2. Use group_wait and group_interval in Alertmanager
route:
  group_wait: 30s                  # Collect related alerts before notifying
  repeat_interval: 4h              # Resend max every 4h

# 3. Inhibition rules — suppress downstream alerts
inhibit_rules:
- source_match:
    alertname: NodeDown
  target_match_re:
    alertname: "Pod.*|Deployment.*"  # If node is down, suppress pod alerts

# 4. Time-based silences (planned maintenance)
# Alertmanager UI → Silences → Create silence with time window

# 5. Severity routing — page for critical, Slack for warning
# 6. Runbook links — when alert context is clear, people act faster
# 7. Review alert noise monthly — kill alerts nobody acts on
```
