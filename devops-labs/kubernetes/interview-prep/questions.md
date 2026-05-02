# Kubernetes Interview Preparation

> 20 scenario-based questions. Every answer includes hands-on context.

---

## Q1. A pod is stuck in `Pending` state. Walk me through your diagnosis.

**Answer:**

```bash
# Step 1: Describe the pod — read the Events section
kubectl describe pod <pod-name> -n <namespace>

# Common causes and what Events say:
# "0/3 nodes are available: 3 Insufficient cpu"
#   → Resources requested > available. Check:
kubectl describe nodes | grep -A5 "Allocated resources"
kubectl top nodes

# "0/3 nodes are available: 3 node(s) had taint {key:NoSchedule}"
#   → Pod doesn't tolerate the node taint. Add toleration or remove taint.
kubectl get nodes -o json | jq '.items[].spec.taints'

# "0/3 nodes are available: 3 didn't match Pod's node affinity"
#   → nodeSelector/nodeAffinity doesn't match any node.
kubectl get nodes --show-labels

# "persistentvolumeclaim 'my-pvc' not found" or "unbound"
kubectl get pvc -n <namespace>
kubectl describe pvc <pvc-name> -n <namespace>
```

**Resolution checklist:**
1. Resources — reduce requests or add more nodes
2. Taints — add tolerations or label nodes correctly
3. Affinity — fix nodeSelector labels
4. PVC — check StorageClass, provisioner, available capacity

---

## Q2. A deployment rollout is stuck. `kubectl rollout status` hangs. What do you do?

**Answer:**

```bash
# Check what's happening
kubectl rollout status deployment/myapp -n production --timeout=2m

# Look at the new ReplicaSet pods
kubectl get pods -n production -l app=myapp
# If new pods are in CrashLoopBackOff or ImagePullBackOff → that's your culprit

# Check the new pod's logs
kubectl logs -l app=myapp --tail=50 -n production
kubectl logs <pod-name> --previous -n production   # Previous container logs (if crashed)

# Most common causes:
# 1. New image doesn't exist → ImagePullBackOff
kubectl describe pod <new-pod> -n production | grep -A10 Events

# 2. App crashes on start → CrashLoopBackOff
kubectl logs <new-pod> -n production

# 3. Readiness probe never passes → pod stays not-ready, rollout waits
kubectl describe pod <new-pod> -n production | grep -A10 Readiness

# 4. Not enough resources to schedule new pod
kubectl describe pod <new-pod> -n production | grep -A5 "Warning\|Error"

# If rollout is clearly broken → rollback immediately
kubectl rollout undo deployment/myapp -n production
kubectl rollout status deployment/myapp -n production
```

---

## Q3. Your app is getting OOMKilled repeatedly. How do you debug and fix it?

**Answer:**

```bash
# Confirm OOMKill
kubectl describe pod <pod> -n production
# Look for: "OOMKilled" in Last State section
# Exit Code 137 = OOMKill

# Get actual memory usage (need metrics-server)
kubectl top pod <pod> -n production
kubectl top pod <pod> --containers -n production

# Check VPA recommendation (if installed)
kubectl describe vpa myapp-vpa -n production

# Short-term fix: increase memory limit
kubectl patch deployment myapp -n production \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"app","resources":{"limits":{"memory":"1Gi"}}}]}}}}'

# Long-term fix: profile the app
# 1. Add memory profiling endpoint (pprof for Go, memory_profiler for Python)
# 2. Check for memory leaks — objects not being garbage collected
# 3. Check for large in-memory caches
# 4. Check for connection pool leaks
# 5. Use VPA to automatically right-size

# Prevent OOMKill from cascading (PDB)
kubectl get pdb -n production
```

---

## Q4. Explain the difference between liveness, readiness, and startup probes.

**Answer:**

| Probe | Question it answers | Action on failure |
|-------|---------------------|-------------------|
| Startup | Has app finished starting? | Kills container (restart) |
| Liveness | Is app alive/healthy? | Kills container (restart) |
| Readiness | Is app ready for traffic? | Removes from Service endpoints (no restart) |

**Real scenario**: Node.js app that takes 45s to start:

```yaml
startupProbe:
  httpGet:
    path: /health
    port: 3000
  failureThreshold: 12     # 12 × 5s = 60s max start window
  periodSeconds: 5
  # Once startup passes, liveness/readiness take over

livenessProbe:             # If app deadlocks, this detects and restarts it
  httpGet:
    path: /health/live
    port: 3000
  periodSeconds: 10
  failureThreshold: 3      # 3 × 10s = restart after 30s of unhealthy

readinessProbe:            # During rolling update: only route traffic to ready pods
  httpGet:
    path: /health/ready
    port: 3000
  periodSeconds: 5
  failureThreshold: 3
```

**Common mistake**: Using the same endpoint for all three. If your app is in a recoverable state, only liveness should restart it. Readiness is for temporary unavailability (e.g., warming cache).

---

## Q5. How does Kubernetes networking work? A pod can't reach another pod.

**Answer:**

**K8s networking rules:**
1. Every pod gets a unique IP
2. Any pod can reach any other pod without NAT
3. Services provide stable virtual IPs via kube-proxy

**Debug steps:**

```bash
# From the source pod, can it reach the target?
kubectl exec -it source-pod -- wget -qO- http://target-svc:8080/health

# Is the target Service healthy?
kubectl get endpoints target-svc -n <namespace>
# Empty ENDPOINTS = no pods match the selector

# Check selector matches
kubectl get svc target-svc -o yaml | grep selector -A5
kubectl get pods -l app=target -o wide    # Do label match?

# DNS resolution working?
kubectl exec -it source-pod -- nslookup target-svc.namespace.svc.cluster.local

# Network policy blocking?
kubectl get networkpolicy -n <namespace>
# If policies exist, trace source → destination rules

# CNI issue? Check node-to-node connectivity
kubectl get pods -n kube-system | grep calico  # or cilium, flannel

# Port mismatch?
kubectl get svc target-svc -o yaml  # Check port vs targetPort
kubectl describe pod target-pod | grep -i "port"
```

---

## Q6. What is the difference between a StatefulSet and a Deployment?

**Answer:**

| Feature | Deployment | StatefulSet |
|---------|-----------|-------------|
| Pod identity | Random (pod-abc123) | Stable ordered (pod-0, pod-1) |
| Storage | Shared or none | Unique PVC per pod |
| Scaling order | Parallel | Ordered (0→1→2) |
| Deletion order | Parallel | Reverse ordered (2→1→0) |
| Network identity | Ephemeral IP | Stable DNS via headless service |
| Use case | Stateless apps | Databases, message queues |

**When StatefulSet matters for databases:**
- `postgres-0` is always the primary, `postgres-1` is always replica-1
- Replication is configured using stable hostnames, not IPs
- Each pod has its own PVC — data survives pod restarts
- Ordered startup ensures primary is up before replicas join

---

## Q7. Explain RBAC in Kubernetes. How would you give a CI/CD pipeline deploy access?

**Answer:**

RBAC components:
- **Role/ClusterRole**: List of permissions (verbs on resources)
- **RoleBinding/ClusterRoleBinding**: Who gets those permissions
- **Subject**: User, Group, or ServiceAccount

```bash
# Create SA for CI/CD
kubectl create serviceaccount cicd-deployer -n staging

# Create minimal deploy role
cat << 'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: deployer-role
  namespace: staging
rules:
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "update", "patch"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["configmaps", "services"]
  verbs: ["get", "create", "update", "patch"]
EOF

kubectl create rolebinding cicd-binding \
  --role=deployer-role \
  --serviceaccount=staging:cicd-deployer \
  -n staging

# Generate token for CI/CD system
kubectl create token cicd-deployer -n staging --duration=8760h

# Test permissions
kubectl auth can-i update deployments \
  --as=system:serviceaccount:staging:cicd-deployer \
  -n staging
```

---

## Q8. Your node is NotReady. What do you do?

**Answer:**

```bash
# Check which node
kubectl get nodes
# NAME        STATUS     ROLES    AGE
# node-3      NotReady   <none>   5d

# Check node conditions
kubectl describe node node-3 | grep -A20 "Conditions:"
# Common conditions: MemoryPressure, DiskPressure, PIDPressure, Ready=False

# SSH to the node and check kubelet
systemctl status kubelet
journalctl -u kubelet -n 50

# Common causes:
# 1. Kubelet stopped → systemctl restart kubelet
# 2. Disk full → df -h, clean up /var/lib/docker or /var/log
# 3. OOM → dmesg | grep -i oom
# 4. Container runtime down → systemctl status containerd
# 5. Network plugin crashed → kubectl get pods -n kube-system | grep calico/cilium

# Immediate action: cordon node (no new pods scheduled)
kubectl cordon node-3

# Move workloads off (if critical)
kubectl drain node-3 --ignore-daemonsets --delete-emissary-data

# After fixing:
kubectl uncordon node-3
```

---

## Q9. How do you implement zero-downtime deployments?

**Answer:**

**Three requirements:**

1. **Proper readiness probe** — don't route traffic until app is ready
2. **Rolling update strategy** with `maxUnavailable: 0`
3. **`preStop` hook** — allow in-flight requests to finish

```yaml
spec:
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1          # 1 extra pod during update
      maxUnavailable: 0    # Never kill a pod before replacement is ready

  template:
    spec:
      containers:
      - name: app
        readinessProbe:    # New pod must pass this before old pod is killed
          httpGet:
            path: /ready
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 5
        lifecycle:
          preStop:
            exec:
              command: ["/bin/sh", "-c", "sleep 15"]  # Drain in-flight requests
      terminationGracePeriodSeconds: 30
```

**With PodDisruptionBudget** (protects against node drains):
```yaml
spec:
  minAvailable: "75%"    # Always keep 75% of pods running
```

---

## Q10. What is etcd and why does it matter for DR?

**Answer:**

etcd is the **key-value store** that holds all cluster state — pods, deployments, services, secrets, configmaps, RBAC, etc.

**DR implications:**
- If etcd is lost → entire cluster state is gone
- All running workloads continue (containers keep running on nodes)
- But you can't create/update/delete anything
- Cluster slowly diverges from desired state

**Production setup:**
- 3 or 5 node cluster (Raft quorum)
- Separate etcd nodes from control plane (large clusters)
- Encrypt etcd at rest (`--encryption-provider-config`)
- Daily backups to S3/GCS

```bash
# Backup
ETCDCTL_API=3 etcdctl snapshot save snapshot.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key

# Verify backup
ETCDCTL_API=3 etcdctl snapshot status snapshot.db

# Restore (on new cluster)
ETCDCTL_API=3 etcdctl snapshot restore snapshot.db \
  --data-dir=/var/lib/etcd-restore
```

---

## Q11. How does HPA work? What are its limitations?

**Answer:**

HPA polling cycle (every 15s):
1. Query metrics API (metrics-server or Prometheus Adapter)
2. Calculate desired replicas = `ceil(currentReplicas × currentMetric / targetMetric)`
3. Apply stabilization window to prevent flapping
4. Scale if outside min/max bounds

**Limitations:**
- Can't scale to zero (use KEDA)
- Latency: metrics scrape interval (15s) + HPA poll (15s) = up to 30s lag
- CPU-based HPA is reactive — already overloaded by the time it acts
- Doesn't account for cold start time of new pods

**Best practices:**
- Set `stabilizationWindowSeconds` for scale-down (prevents flapping)
- Use custom metrics (RPS, queue depth) instead of just CPU
- Combine with KEDA for event-driven and scale-to-zero
- Pre-scale before known events (Black Friday, marketing campaigns)

---

## Q12. Explain the difference between ClusterIP, NodePort, and LoadBalancer services.

**Answer:**

```
ClusterIP:    Only reachable inside the cluster
              Use for: service-to-service communication
              DNS: my-svc.namespace.svc.cluster.local

NodePort:     Reachable on <NodeIP>:<NodePort> from outside
              Use for: dev/testing, on-prem without cloud LB
              Port range: 30000-32767

LoadBalancer: Cloud-provisioned external load balancer
              Use for: production internet-facing services
              Creates: NodePort + ClusterIP automatically
              Cost: Each LB costs money (~$15-25/month on AWS)
```

**Cost optimization**: In production, use one LoadBalancer (Ingress Controller) for ALL services instead of a LoadBalancer per service.

```
Internet → 1 AWS ALB (LoadBalancer) → nginx-ingress → multiple services
                                    ↗ /api    → api-service (ClusterIP)
                                    ↗ /app    → frontend (ClusterIP)
                                    ↗ /admin  → admin (ClusterIP)
```

---

## Q13. A secret is needed by pods in multiple namespaces. How do you handle it?

**Answer:**

K8s Secrets are namespace-scoped. Options:

```bash
# Option 1: Replicate secret (simple but maintenance burden)
kubectl get secret my-secret -n source-ns -o yaml | \
  sed 's/namespace: source-ns/namespace: target-ns/' | \
  kubectl apply -f -

# Option 2: External Secrets Operator (production best practice)
# Single secret in AWS Secrets Manager → synced to multiple namespaces
# Each namespace gets its own ExternalSecret that points to the same source

# Option 3: Reflector (auto-replicates secrets across namespaces)
helm install reflector emberstack/reflector

# Annotate source secret
kubectl annotate secret my-secret \
  reflector.v1.k8s.emberstack.com/reflection-allowed="true" \
  reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces="ns1,ns2,ns3"

# Option 4: HashiCorp Vault with Vault Agent Injector
# Vault injects secret as a file/env var at pod startup
# No K8s Secret object created at all
```

**Recommendation**: Use External Secrets Operator for production. Single source of truth, audit trail, rotation support.

---

## Q14. How do you debug a service that's returning 502 errors?

**Answer:**

502 = Bad Gateway. The Ingress or Load Balancer reached the Service/Pod, but got an error.

```bash
# Step 1: Check pod health
kubectl get pods -n production -l app=myapp
# Are pods Running? Any restarts?

# Step 2: Check logs for errors
kubectl logs -l app=myapp -n production --tail=50 | grep -i error

# Step 3: Can you hit the pod directly?
POD_IP=$(kubectl get pod <pod-name> -n production -o jsonpath='{.status.podIP}')
kubectl run debug --image=curlimages/curl --rm -it -- curl http://$POD_IP:8080/health

# Step 4: Can you hit the Service?
kubectl run debug --image=curlimages/curl --rm -it -- \
  curl http://myapp.production.svc.cluster.local/health

# Step 5: Check Ingress events
kubectl describe ingress myapp-ingress -n production

# Step 6: Check Ingress Controller logs
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --tail=100 | grep 502

# Common causes:
# - Pod not ready (readiness probe failing) → endpoints empty
# - Port mismatch (Service targetPort ≠ containerPort)
# - App returning non-200 on health endpoint
# - Resource limits causing OOM/CPU throttling
# - Connection pool exhausted (DB connections)
```

---

## Q15. What is a PodDisruptionBudget and when do you need it?

**Answer:**

PDB defines minimum availability during **voluntary disruptions** (node drains, upgrades, evictions).

**Without PDB**: During `kubectl drain node-1`, ALL pods on that node can be terminated simultaneously → downtime.

**With PDB**:
```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: api-pdb
spec:
  minAvailable: 2       # Or use maxUnavailable: 1
  selector:
    matchLabels:
      app: api-service
```

If you have 3 replicas and `minAvailable: 2`, drain can only evict 1 pod at a time. Waits until a replacement is scheduled elsewhere before evicting another.

**Real scenario**: Cluster upgrade (node pool replacement):
```
Without PDB: All 3 pods on node drain → 0 available → downtime
With PDB:    Drain waits for replacement pod before evicting next → 0 downtime
```

**When to use**: Any Deployment with >1 replica that handles production traffic.

---

## Q16. Explain Kubernetes scheduling. How do you influence where pods are placed?

**Answer:**

**Tools for placement control:**

```yaml
# 1. nodeSelector — hard requirement (simple)
spec:
  nodeSelector:
    disk-type: ssd

# 2. nodeAffinity — flexible rules
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:   # Hard rule
        nodeSelectorTerms:
        - matchExpressions:
          - key: zone
            operator: In
            values: [us-east-1a, us-east-1b]
      preferredDuringSchedulingIgnoredDuringExecution:  # Soft preference
      - weight: 100
        preference:
          matchExpressions:
          - key: disk-type
            operator: In
            values: [ssd]

# 3. podAntiAffinity — spread replicas across nodes/zones
spec:
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app: myapp
        topologyKey: kubernetes.io/hostname  # Never 2 replicas on same node

# 4. Taints + Tolerations — reserve nodes for specific workloads
# Taint a node (only pods with matching toleration can schedule)
kubectl taint nodes gpu-node-1 accelerator=gpu:NoSchedule

# Toleration in pod spec
spec:
  tolerations:
  - key: accelerator
    operator: Equal
    value: gpu
    effect: NoSchedule

# 5. TopologySpreadConstraints — evenly spread across zones
spec:
  topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app: myapp
```

---

## Q17. How would you migrate a stateful application from one cluster to another?

**Answer:**

This is a production-critical operation. Follow this sequence:

```bash
# Phase 1: Prepare (no downtime)
# 1. Backup data
kubectl exec -it postgres-0 -- pg_dump $DATABASE_URL | gzip > backup.sql.gz
aws s3 cp backup.sql.gz s3://backups/migration/

# 2. Set up new cluster with same StorageClass
# 3. Restore data to new cluster
# 4. Set up replication from old → new (if zero-downtime required)

# Phase 2: Switch over (brief downtime window)
# 1. Announce maintenance window
# 2. Scale down old app (stop writes)
kubectl scale deployment myapp --replicas=0 -n production

# 3. Final data sync
kubectl exec -it postgres-0 -n old-cluster -- pg_dump $DB | \
  kubectl exec -i postgres-0 -n new-cluster -- psql $DB

# 4. Update DNS to point to new cluster LB
# 5. Scale up app in new cluster
kubectl scale deployment myapp --replicas=3 -n new-cluster

# Phase 3: Verify and cleanup
kubectl get pods -n new-cluster
curl https://api.company.com/health

# Keep old cluster running for 24h as fallback
# Then decommission
```

---

## Q18. What is Helm and when would you use it vs Kustomize?

**Answer:**

| | Helm | Kustomize |
|-|------|-----------|
| Approach | Templating (Go templates + values) | Patching (overlay base manifests) |
| Versioning | Chart versioning, rollback | Git is the version control |
| Dependencies | Built-in dependency management | Manual |
| Learning curve | Higher (templates can get complex) | Lower |
| Best for | Distributing reusable packages | Environment-specific overlays |

**Real-world pattern: Use both together**

```
# Use Helm for third-party tools (install once, configure via values)
helm install prometheus prometheus-community/kube-prometheus-stack -f prod-values.yaml

# Use Kustomize for your own apps (manage per-environment differences)
kustomize build apps/api-service/overlays/production | kubectl apply -f -
```

**Kustomize for environment differences:**
```
base/              # Common manifests
  deployment.yaml  # 2 replicas, default image
overlays/
  production/
    kustomization.yaml  # 10 replicas, prod image tag, prod ConfigMap
  staging/
    kustomization.yaml  # 2 replicas, staging image tag
```

---

## Q19. Describe a Kubernetes outage you would investigate with these symptoms: "API returns 503, pods are running, no recent deployments."

**Answer:**

503 = Service unavailable from the load balancer/ingress.

```bash
# Step 1: Check Ingress Controller
kubectl get pods -n ingress-nginx
# Are ingress controller pods running?

kubectl logs -n ingress-nginx -l app=ingress-nginx --tail=100 | grep -E "error|ERR|503"

# Step 2: Check if endpoints are populated
kubectl get endpoints myapp-svc -n production
# Empty endpoints = Service selector doesn't match any Ready pods

# Step 3: Why are pods not ready?
kubectl get pods -n production -l app=myapp
# Status column: are they Running/Ready?
kubectl describe pod <pod> -n production | grep -A5 "Conditions"

# Step 4: Certificate expired?
kubectl get certificate -n production
kubectl describe certificate myapp-tls -n production | grep -A5 "Status"

# Step 5: ConfigMap/Secret changed?
kubectl get events -n production --sort-by=.lastTimestamp | tail -20

# Step 6: Resource pressure?
kubectl top nodes
kubectl describe nodes | grep -A5 "Conditions"

# Step 7: Check kube-proxy
kubectl get pods -n kube-system | grep kube-proxy
kubectl logs -n kube-system kube-proxy-<pod> | tail -20

# Likely culprits:
# - Cert expired → cert-manager issue
# - ConfigMap change broke app → readiness probe failing
# - Node memory pressure → pods being evicted
# - Network policy added that blocks ingress controller
```

---

## Q20. How do you optimize Kubernetes costs in production?

**Answer:**

```bash
# 1. Right-size pods with VPA recommendations
kubectl describe vpa -A | grep -A5 "Recommendation"

# 2. Use spot/preemptible nodes for stateless workloads
# Label spot nodes, add tolerations to Deployments

# 3. Scale to zero with KEDA for batch/dev workloads
# Saves ~70% on dev/staging clusters overnight

# 4. Set resource quotas per namespace
# Prevents teams from over-provisioning

# 5. Delete idle resources
kubectl get deployments -A | grep -v NAMESPACE | awk '$3==0{print $1,$2}'
# Scale or delete zero-replica deployments

# 6. Use cluster autoscaler
# Removes empty nodes, adds nodes on demand

# 7. Namespace-based cost allocation
# Label namespaces with team/cost-center, use Kubecost for breakdown

# 8. Optimize Docker images (smaller = faster pull = less cost)
# Multi-stage builds, alpine base images, .dockerignore

# 9. Reserved instances for baseline, spot for burst
# 70% reserved + 30% spot = ~40% savings vs all on-demand

# 10. Storage optimization
# Delete unbound PVCs, use lifecycle policies on S3
kubectl get pvc -A | grep -v Bound
```

---

## Common Follow-up Questions

- "What is the difference between `kubectl apply` and `kubectl create`?"
  → `apply` is declarative (idempotent), `create` is imperative (fails if exists)

- "What happens if you delete a namespace?"
  → All resources inside are deleted. PVs with `Retain` policy remain.

- "How does cert-manager work?"
  → Watches Certificate objects, requests certs from ACME (Let's Encrypt), stores in Secrets, auto-renews before expiry.

- "What is a mutating admission webhook?"
  → Intercepts API server requests, can modify objects before they're stored. Example: inject sidecar containers, set default labels.
