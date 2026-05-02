# AIOps

> **Artificial Intelligence for IT Operations — intelligent alerting, anomaly detection, and autonomous remediation.**

---

## Quick Navigation

| Section | Contents |
|---------|----------|
| [docs/01-concepts.md](docs/01-concepts.md) | AIOps principles, anomaly detection, intelligent alerting |
| [docs/02-llmops.md](docs/02-llmops.md) | LLM-powered ops tools, AI assistant for incidents |
| [examples/](examples/) | Anomaly detection scripts, intelligent runbooks |
| [interview-prep/questions.md](interview-prep/questions.md) | 15 interview Q&A |

---

## AIOps Definition

```
AIOps = AI + Big Data + ML applied to IT Operations

Goals:
  1. Correlate alerts from many sources → single incident
  2. Detect anomalies before humans notice
  3. Predict failures before they happen
  4. Automate remediation for known issues
  5. Reduce MTTD and MTTR

Data sources:
  Metrics (Prometheus, CloudWatch)
  Logs (Loki, Elasticsearch)
  Traces (Jaeger, Tempo)
  Events (K8s events, deploys)
  Topology (service dependencies)
```

---

## The AIOps Stack

```
Data Collection:    Prometheus, Loki, Jaeger, K8s events
Data Platform:      Kafka/Kinesis (streaming), BigQuery/S3 (storage)
ML Layer:           Anomaly detection, RCA correlation, prediction
Automation:         Auto-remediation, runbook execution, Slack bot
Observability:      Grafana, custom dashboards, AI-powered alerts
```
