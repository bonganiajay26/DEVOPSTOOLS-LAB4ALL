# Kubernetes Core Concepts

## The Mental Model

Kubernetes is a **desired-state system**. You declare what you want; the control loop makes it real and keeps it that way.

```
You declare:  "I want 3 replicas of my app running"
K8s ensures:  If one crashes, it restarts it. Always 3.
```

---

## Object Hierarchy

```
Cluster
└── Namespace
    ├── Pod           ← smallest deployable unit (1+ containers)
    ├── Deployment    ← manages ReplicaSets → manages Pods
    ├── Service       ← stable network endpoint for Pods
    ├── ConfigMap     ← non-secret config data
    ├── Secret        ← sensitive data (base64 encoded)
    ├── PersistentVolumeClaim  ← request for storage
    ├── Ingress       ← HTTP/S routing rules
    └── ServiceAccount ← identity for Pods
```

---

## Core Objects Explained

### Pod
The atomic unit. One or more tightly-coupled containers that share:
- Network namespace (same IP, same localhost)
- Storage volumes
- Lifecycle

**Never create bare Pods in production.** Always use a controller (Deployment, StatefulSet, DaemonSet).

```yaml
# What a Pod spec looks like (inside a Deployment)
spec:
  containers:
  - name: app
    image: myapp:1.0
    ports:
    - containerPort: 8080
    resources:
      requests:
        cpu: "100m"
        memory: "128Mi"
      limits:
        cpu: "500m"
        memory: "512Mi"
```

### Deployment
Manages stateless applications. Provides:
- Rolling updates (zero downtime)
- Rollback (`kubectl rollout undo`)
- Scaling (`kubectl scale`)
- Self-healing (restart crashed pods)

```
Deployment
  └── ReplicaSet (current version)
        ├── Pod-1
        ├── Pod-2
        └── Pod-3
  └── ReplicaSet (previous version — kept for rollback)
```

### Service
Stable virtual IP + DNS name in front of dynamic Pods.

| Type | Use Case |
|------|----------|
| ClusterIP | Internal cluster communication (default) |
| NodePort | Expose on each node's IP:port (dev/testing) |
| LoadBalancer | Cloud load balancer (production) |
| ExternalName | DNS alias to external service |

Selector-based routing: Service finds Pods via label matching.
```yaml
selector:
  app: myapp      # matches Pods with label app=myapp
```

### ConfigMap
Decouple config from container image.
- Environment variables
- Config files mounted as volumes
- Command-line arguments

**Rule**: If it changes between environments (dev/staging/prod), put it in a ConfigMap.

### Secret
Same as ConfigMap but for sensitive data. Base64 encoded (NOT encrypted by default — use Sealed Secrets or Vault for real encryption at rest).

Types:
- `Opaque` — arbitrary key-value pairs
- `kubernetes.io/tls` — TLS certificates
- `kubernetes.io/dockerconfigjson` — registry credentials

### Namespace
Soft multi-tenancy. Isolate teams, environments, or applications.

Common pattern:
```
namespaces:
  production
  staging
  development
  monitoring
  platform
```

Resource quotas and RBAC are applied per-namespace.

---

## Controllers

### StatefulSet
For stateful workloads (databases, message queues):
- Stable, unique pod names (pod-0, pod-1, pod-2)
- Ordered deployment and scaling
- Stable persistent storage per pod
- Stable network identity

Use for: PostgreSQL, MySQL, Kafka, Zookeeper, Redis Cluster.

### DaemonSet
Run one pod per node (or per selected nodes).

Use for: Log collectors (Fluentd), monitoring agents (Prometheus node-exporter), network plugins, security agents.

### Job / CronJob
- `Job`: Run to completion (batch processing, DB migrations)
- `CronJob`: Scheduled jobs (reports, cleanup tasks)

---

## Networking Model

**Rule**: Every Pod gets a unique cluster-wide IP. Any Pod can reach any other Pod without NAT.

```
Pod A (10.244.1.5) ──► Service (10.96.100.1:80) ──► Pod B (10.244.2.3:8080)
                                                   └──► Pod C (10.244.3.7:8080)
```

**DNS**: Every Service gets a DNS name:
```
<service-name>.<namespace>.svc.cluster.local
# Example: postgres.database.svc.cluster.local
```

---

## Labels and Selectors

Labels are the glue. Everything in Kubernetes uses label selectors.

```yaml
# On a Pod (set by Deployment)
metadata:
  labels:
    app: frontend
    version: v2
    env: production
    tier: web

# On a Service (selects those Pods)
spec:
  selector:
    app: frontend
    tier: web
```

Recommended label schema:
```yaml
app.kubernetes.io/name: myapp
app.kubernetes.io/version: "1.2.3"
app.kubernetes.io/component: frontend
app.kubernetes.io/part-of: my-platform
app.kubernetes.io/managed-by: helm
```

---

## Probes (Health Checks)

```yaml
livenessProbe:    # Is the container alive? If not → restart it
  httpGet:
    path: /healthz
    port: 8080
  initialDelaySeconds: 10
  periodSeconds: 10

readinessProbe:   # Is the container ready to serve traffic? If not → remove from Service endpoints
  httpGet:
    path: /ready
    port: 8080
  initialDelaySeconds: 5
  periodSeconds: 5

startupProbe:     # Has the app finished starting? Disables liveness/readiness until it passes
  httpGet:
    path: /started
    port: 8080
  failureThreshold: 30
  periodSeconds: 10
```

---

## Resource Management

Always set requests and limits. This is non-negotiable in production.

```yaml
resources:
  requests:          # Guaranteed minimum (used for scheduling)
    cpu: "100m"      # 100 millicores = 0.1 CPU
    memory: "128Mi"
  limits:            # Hard cap
    cpu: "500m"
    memory: "512Mi"
```

**QoS Classes** (affects eviction order under pressure):
- `Guaranteed`: requests == limits (highest priority)
- `Burstable`: requests < limits
- `BestEffort`: no requests or limits set (evicted first)

---

## Key kubectl Commands

```bash
# Cluster info
kubectl cluster-info
kubectl get nodes -o wide

# Namespace operations
kubectl get all -n <namespace>
kubectl config set-context --current --namespace=<namespace>

# Pod operations
kubectl get pods -o wide
kubectl describe pod <pod-name>
kubectl logs <pod-name> -f --tail=100
kubectl exec -it <pod-name> -- /bin/sh

# Deployment operations
kubectl rollout status deployment/<name>
kubectl rollout history deployment/<name>
kubectl rollout undo deployment/<name>
kubectl scale deployment <name> --replicas=5

# Debug
kubectl get events --sort-by=.lastTimestamp
kubectl top pods
kubectl top nodes
```
