# Kubernetes Use Cases & Real-World Patterns

## 1. Microservices Platform

**Scenario**: E-commerce company running 50+ microservices.

```
┌─────────────────────────────────────────────────────────────┐
│                    Production Cluster                        │
│                                                              │
│  namespace: frontend                                         │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐                     │
│  │  React  │  │  Next   │  │  CDN    │                     │
│  │  App    │  │  .js    │  │ Proxy   │                     │
│  └────┬────┘  └────┬────┘  └────┬────┘                     │
│       └────────────┴────────────┘                           │
│                    │ API Gateway                             │
│  namespace: backend│                                         │
│  ┌─────────┐  ┌────┴────┐  ┌─────────┐  ┌─────────┐       │
│  │ Auth    │  │ Product │  │ Order   │  │ Payment │       │
│  │ Service │  │ Service │  │ Service │  │ Service │       │
│  └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘       │
│       │            │            │             │             │
│  namespace: data                                             │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐                     │
│  │ Postgres│  │  Redis  │  │  Kafka  │                     │
│  │ (SS)    │  │ Cluster │  │ Cluster │                     │
│  └─────────┘  └─────────┘  └─────────┘                     │
└─────────────────────────────────────────────────────────────┘
```

**Key Kubernetes features used**:
- Namespace isolation per tier
- HPA for frontend (scales 2→50 pods on traffic spikes)
- StatefulSets for databases
- NetworkPolicies (frontend cannot talk to data tier directly)
- PodDisruptionBudgets (always keep minimum replicas during maintenance)

---

## 2. Blue/Green Deployments

**Scenario**: Zero-downtime major version release.

```bash
# Current state: blue (v1) is live
#
# namespace: production
# Service → selector: version=blue
#
# blue Deployment  (5 replicas, v1) ← LIVE TRAFFIC
# green Deployment (0 replicas, v2) ← IDLE

# Step 1: Scale up green
kubectl scale deployment myapp-green --replicas=5

# Step 2: Wait for green to be healthy
kubectl rollout status deployment/myapp-green

# Step 3: Switch traffic (update Service selector)
kubectl patch service myapp \
  -p '{"spec":{"selector":{"version":"green"}}}'

# Step 4: Verify (monitor error rates for 10 min)
# If OK → scale down blue
kubectl scale deployment myapp-blue --replicas=0

# If NOT OK → instant rollback
kubectl patch service myapp \
  -p '{"spec":{"selector":{"version":"blue"}}}'
```

---

## 3. Canary Releases

**Scenario**: Test new version with 10% of traffic before full rollout.

```yaml
# stable: 9 replicas
# canary: 1 replica
# Result: ~10% traffic hits canary
#
# Both Deployments share same Service selector: app=myapp

# stable-deployment.yaml
metadata:
  name: myapp-stable
spec:
  replicas: 9
  selector:
    matchLabels:
      app: myapp
      track: stable

# canary-deployment.yaml
metadata:
  name: myapp-canary
spec:
  replicas: 1
  selector:
    matchLabels:
      app: myapp
      track: canary

# Service selects BOTH via common label
spec:
  selector:
    app: myapp   # matches both stable and canary pods
```

---

## 4. Batch Processing / ML Training Jobs

**Scenario**: Nightly ML model training on GPU nodes.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: train-model-v2
spec:
  parallelism: 4        # Run 4 pods in parallel
  completions: 16       # Total work units
  backoffLimit: 3       # Retry failed pods up to 3 times
  template:
    spec:
      nodeSelector:
        accelerator: nvidia-tesla-v100
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
      containers:
      - name: trainer
        image: myml/trainer:latest
        resources:
          limits:
            nvidia.com/gpu: 1
        env:
        - name: BATCH_ID
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
      restartPolicy: OnFailure
```

---

## 5. Multi-Tenant SaaS Platform

**Scenario**: Each customer gets isolated namespace with resource quotas.

```yaml
# Tenant namespace template
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-acme-corp
  labels:
    tenant: acme-corp
    tier: enterprise
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tenant-quota
  namespace: tenant-acme-corp
spec:
  hard:
    requests.cpu: "10"
    requests.memory: 20Gi
    limits.cpu: "20"
    limits.memory: 40Gi
    pods: "50"
    services: "20"
    persistentvolumeclaims: "10"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: tenant-limits
  namespace: tenant-acme-corp
spec:
  limits:
  - type: Container
    default:
      cpu: "500m"
      memory: "512Mi"
    defaultRequest:
      cpu: "100m"
      memory: "128Mi"
    max:
      cpu: "4"
      memory: "8Gi"
```

---

## 6. Auto-Scaling on Load

**Scenario**: API service needs to handle Black Friday traffic (100x normal).

```yaml
# HPA: Scale based on CPU + custom metrics
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api-service
  minReplicas: 3
  maxReplicas: 100
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 60
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
  - type: External
    external:
      metric:
        name: requests_per_second
      target:
        type: AverageValue
        averageValue: "1000"
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
      - type: Percent
        value: 100     # Double pods every 60s
        periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300  # Don't scale down for 5 min
```

---

## 7. Disaster Recovery Pattern

**Scenario**: Database failure during business hours.

```bash
# Detect: Prometheus alert fires → PagerDuty → On-call engineer

# 1. Check what happened
kubectl describe pod postgres-0 -n database
kubectl logs postgres-0 -n database --previous

# 2. Check persistent volume
kubectl get pvc -n database
kubectl describe pvc postgres-pvc-0 -n database

# 3. If node failure — cordon and drain
kubectl cordon node-3
kubectl drain node-3 --ignore-daemonsets --delete-emissary-data

# 4. StatefulSet automatically reschedules postgres-0 on healthy node
kubectl rollout status statefulset/postgres -n database

# 5. Restore from backup if data corruption
kubectl exec -it postgres-0 -n database -- \
  psql -U postgres -c "SELECT pg_last_wal_receive_lsn();"
```

---

## 8. Secret Management with Vault Integration

**Scenario**: Inject secrets from HashiCorp Vault into pods without storing them in K8s Secrets.

```yaml
# Using Vault Agent Injector (sidecar pattern)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
spec:
  template:
    metadata:
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "myapp-role"
        vault.hashicorp.com/agent-inject-secret-config: "secret/myapp/config"
        vault.hashicorp.com/agent-inject-template-config: |
          {{- with secret "secret/myapp/config" -}}
          DATABASE_URL={{ .Data.data.database_url }}
          API_KEY={{ .Data.data.api_key }}
          {{- end -}}
    spec:
      serviceAccountName: myapp-vault-sa
      containers:
      - name: app
        image: myapp:1.0
        # Vault injects secrets to /vault/secrets/config
        # App reads from that file
```

---

## 9. GitOps Continuous Deployment

**Scenario**: Any push to main branch triggers automatic cluster update.

```
Developer pushes code
         │
    GitHub Actions
    ├── Run tests
    ├── Build Docker image
    ├── Push to ECR
    └── Update image tag in GitOps repo
                    │
              ArgoCD watches GitOps repo
                    │
              Detects drift (new image tag)
                    │
              Syncs to cluster
                    │
              Deployment rolling update
                    │
              Health checks pass ✓
```

---

## 10. Cost Optimization with Spot/Preemptible Nodes

**Scenario**: Reduce compute costs by 70% using spot instances for non-critical workloads.

```yaml
# Node pools:
# - on-demand: control plane + databases
# - spot: stateless workloads

# Deployment for stateless app on spot
spec:
  template:
    spec:
      tolerations:
      - key: "cloud.google.com/gke-spot"
        operator: "Equal"
        value: "true"
        effect: "NoSchedule"
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            preference:
              matchExpressions:
              - key: cloud.google.com/gke-spot
                operator: In
                values: ["true"]
      # Handle spot interruptions gracefully
      terminationGracePeriodSeconds: 30
```
