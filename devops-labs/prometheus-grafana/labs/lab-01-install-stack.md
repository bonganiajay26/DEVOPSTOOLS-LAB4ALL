# Lab 01: Install Full Observability Stack

**Difficulty**: Intermediate | **Time**: 45 minutes  
**Goal**: Install Prometheus, Grafana, and AlertManager on a Kubernetes cluster and instrument an app.

---

## Part 1: Install kube-prometheus-stack

```bash
# Create cluster
kind create cluster --name observability-lab

# Add Helm repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Create monitoring namespace
kubectl create namespace monitoring

# Install with production-like values
cat > monitoring-values.yaml << 'EOF'
grafana:
  adminPassword: "admin123"
  persistence:
    enabled: false    # Lab: skip persistence
  dashboardProviders:
    dashboardproviders.yaml:
      apiVersion: 1
      providers:
      - name: default
        orgId: 1
        folder: ''
        type: file
        disableDeletion: false
        options:
          path: /var/lib/grafana/dashboards/default
  dashboards:
    default:
      node-exporter:
        gnetId: 1860     # Import Node Exporter Full dashboard
        revision: 37
        datasource: Prometheus
      kubernetes-cluster:
        gnetId: 6417
        revision: 1
        datasource: Prometheus

prometheus:
  prometheusSpec:
    retention: 2d
    serviceMonitorSelector: {}
    serviceMonitorNamespaceSelector: {}
    podMonitorSelector: {}
    ruleNamespaceSelector: {}

alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          resources:
            requests:
              storage: 1Gi
EOF

helm install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values monitoring-values.yaml \
  --version 58.0.0 \
  --wait

# Verify all pods are running
kubectl get pods -n monitoring
```

---

## Part 2: Access the Dashboards

```bash
# Start port-forwards in background
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80 &
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093 &

echo "Grafana:      http://localhost:3000  (admin/admin123)"
echo "Prometheus:   http://localhost:9090"
echo "Alertmanager: http://localhost:9093"
```

### Explore Prometheus UI

```bash
# Open http://localhost:9090

# Query 1: All targets being scraped
# Status → Targets (should show kube-apiserver, nodes, pods, etc.)

# Query 2: Node CPU usage
# Enter in expression:
1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) by (instance)

# Query 3: Pod restarts
increase(kube_pod_container_status_restarts_total[1h]) > 0

# Query 4: Memory usage
container_memory_usage_bytes{namespace="monitoring"}
```

### Explore Grafana

```
1. Open http://localhost:3000
2. Login: admin/admin123
3. Dashboards → Browse → Default
4. Click "Node Exporter Full" (Dashboard ID 1860)
   - CPU cores, memory, disk, network
5. Click "Kubernetes Cluster Overview" (ID 6417)
   - Pod counts, node status, namespace breakdown
```

---

## Part 3: Deploy and Instrument an App

```bash
# Deploy a sample app with Prometheus metrics
cat << 'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sample-app
  namespace: default
  labels:
    app: sample-app
spec:
  replicas: 3
  selector:
    matchLabels:
      app: sample-app
  template:
    metadata:
      labels:
        app: sample-app
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
        prometheus.io/path: "/metrics"
    spec:
      containers:
      - name: app
        image: prom/prometheus:latest
        args:
          - "--config.file=/etc/prometheus/prometheus.yml"
          - "--web.listen-address=:8080"
        ports:
        - containerPort: 8080
          name: metrics
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: sample-app
  namespace: default
  labels:
    app: sample-app
spec:
  selector:
    app: sample-app
  ports:
  - name: metrics
    port: 8080
    targetPort: 8080
EOF

# Create ServiceMonitor to tell Prometheus to scrape it
cat << 'EOF' | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: sample-app
  namespace: default
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app: sample-app
  endpoints:
  - port: metrics
    interval: 15s
  namespaceSelector:
    matchNames:
    - default
EOF

# Wait for Prometheus to discover the new target
sleep 30

# Check in Prometheus UI: Status → Targets
# Look for: default/sample-app
```

---

## Part 4: Create a Custom Alert

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: lab-alerts
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
  - name: lab-demo
    rules:
    # Alert if any pod has restarted recently
    - alert: PodRestarted
      expr: increase(kube_pod_container_status_restarts_total[15m]) > 0
      for: 0m
      labels:
        severity: info
      annotations:
        summary: "Pod {{ $labels.namespace }}/{{ $labels.pod }} restarted"

    # Alert if deployment has too few replicas
    - alert: DeploymentScaledDown
      expr: kube_deployment_status_replicas_available < kube_deployment_spec_replicas
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "Deployment {{ $labels.namespace }}/{{ $labels.deployment }} under-replicated"
EOF

# Trigger the alert by scaling down
kubectl scale deployment sample-app --replicas=1

# Check Prometheus UI → Alerts → DeploymentScaledDown (should fire after 5m)
# Or check immediately: look for the metric
# kubectl port-forward and query: kube_deployment_status_replicas_available
```

---

## Part 5: Custom Grafana Dashboard

```bash
# Create a ConfigMap with a dashboard definition
cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: sample-app-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  sample-app.json: |
    {
      "title": "Sample App Dashboard",
      "uid": "sample-app-lab",
      "panels": [
        {
          "id": 1,
          "title": "Pod Count",
          "type": "stat",
          "gridPos": {"h": 4, "w": 6, "x": 0, "y": 0},
          "targets": [{
            "expr": "count(kube_pod_status_ready{namespace='default', condition='true'})",
            "legendFormat": "Ready Pods"
          }]
        },
        {
          "id": 2,
          "title": "Restarts",
          "type": "timeseries",
          "gridPos": {"h": 8, "w": 12, "x": 0, "y": 4},
          "targets": [{
            "expr": "increase(kube_pod_container_status_restarts_total{namespace='default'}[5m])",
            "legendFormat": "{{pod}}"
          }]
        }
      ]
    }
EOF

# Dashboard appears automatically in Grafana (sidecar auto-imports)
# Go to Grafana → Dashboards → Search "Sample App Dashboard"
```

---

## Cleanup

```bash
# Stop port-forwards
kill $(lsof -ti :3000 :9090 :9093) 2>/dev/null || true

# Delete cluster
kind delete cluster --name observability-lab
```

## What You Learned

- [x] Installing kube-prometheus-stack via Helm
- [x] Prometheus scraping via annotations and ServiceMonitor
- [x] PrometheusRule for custom alerting
- [x] Grafana dashboard auto-provisioning via ConfigMap
- [x] Navigating Prometheus UI for metric exploration
