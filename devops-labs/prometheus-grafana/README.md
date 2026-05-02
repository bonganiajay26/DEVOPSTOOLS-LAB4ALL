# Prometheus + Grafana

> **The production observability stack. Metrics collection, alerting, and dashboards.**

---

## Quick Navigation

| Section | Contents |
|---------|----------|
| [docs/01-prometheus.md](docs/01-prometheus.md) | Architecture, PromQL, alerting |
| [docs/02-grafana.md](docs/02-grafana.md) | Dashboards, panels, templating |
| [examples/](examples/) | Alert rules, dashboards, recording rules |
| [labs/](labs/) | Full observability stack from scratch |
| [interview-prep/questions.md](interview-prep/questions.md) | 15 interview Q&A |

---

## Key Components

```
Data Sources:          Apps expose /metrics endpoint (Prometheus format)
                       node-exporter, kube-state-metrics, custom metrics

Prometheus Server:     Scrapes metrics, stores TSDB, evaluates rules

Alertmanager:          Receives alerts, deduplicates, routes to Slack/PagerDuty

Grafana:               Queries Prometheus, renders dashboards

Thanos/Cortex:         Long-term storage, multi-cluster federation
```

---

## Install Stack (Quick)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set grafana.adminPassword=admin123

kubectl port-forward svc/monitoring-grafana 3000:80 -n monitoring
# Open http://localhost:3000  (admin / admin123)
```
