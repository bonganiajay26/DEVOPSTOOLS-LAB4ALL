# Datadog Observability — Quantum

Production-ready Datadog setup for the Quantum engineering environment.

## Folder Structure

```
datadog/
├── agent-config/          # Agent configuration files
│   ├── datadog.yaml           # Main agent config (Linux/VM)
│   ├── kubernetes-values.yaml # Helm values for Kubernetes DaemonSet
│   └── docker-compose.yaml    # Agent sidecar for Docker Compose
│
├── logs/                  # Log collection configs
│   ├── app-log-config.yaml        # File-based log collection
│   └── kubernetes-pod-annotations.yaml  # K8s auto-log via annotations
│
├── apm/                   # APM instrumentation examples
│   ├── python-instrumentation.py
│   └── node-instrumentation.js
│
├── monitors/              # Alert monitors (Terraform)
│   └── core-monitors.tf       # Error rate, latency, CPU, disk, crash loop
│
├── integrations/          # Service integrations
│   ├── postgres.yaml          # PostgreSQL check config
│   ├── redis.yaml             # Redis check config
│   └── aws.tf                 # AWS integration (Terraform)
│
├── oncall/                # On-call and incident management
│   ├── runbook-template.md        # Copy and fill in per alert
│   └── incident-response-process.md
│
└── scripts/               # Utility scripts
    ├── install-agent-linux.sh  # One-shot Linux agent install
    ├── validate-agent.sh       # Post-install health check
    └── send-test-trace.py      # APM connectivity test
```

## Quick Start

### 1. Install Agent (Linux)
```bash
DD_API_KEY=your_key DD_TAGS="env:production team:platform" \
  bash scripts/install-agent-linux.sh
```

### 2. Install Agent (Kubernetes)
```bash
helm repo add datadog https://helm.datadoghq.com && helm repo update
kubectl create namespace datadog
kubectl create secret generic datadog-secret \
  --from-literal api-key=YOUR_API_KEY \
  --from-literal app-key=YOUR_APP_KEY \
  -n datadog
helm install datadog-agent datadog/datadog -n datadog \
  -f agent-config/kubernetes-values.yaml
```

### 3. Validate
```bash
bash scripts/validate-agent.sh
```

### 4. Deploy monitors
```bash
cd monitors
terraform init
terraform apply -var="service=my-api" -var="env=production"
```

## Tagging Standards

All resources must have these tags:

| Tag | Example values |
|---|---|
| `env` | `production`, `staging`, `development` |
| `service` | `payment-service`, `api-gateway` |
| `team` | `platform`, `backend`, `frontend` |
| `version` | `1.2.3` or git SHA |

## Key Links

| Resource | URL |
|---|---|
| Infrastructure Map | https://app.datadoghq.com/infrastructure/map |
| APM Services | https://app.datadoghq.com/apm/services |
| Log Explorer | https://app.datadoghq.com/logs |
| Monitors | https://app.datadoghq.com/monitors/manage |
| Datadog Status | https://status.datadoghq.com |
