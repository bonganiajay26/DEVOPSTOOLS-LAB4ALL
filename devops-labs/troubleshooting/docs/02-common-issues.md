# Common Production Issues — Quick Reference

## Kubernetes Issues

### Pod Won't Start

```bash
# ImagePullBackOff
# Error: "Failed to pull image"
kubectl describe pod <pod> | grep "Error\|Warning" 
# Fix 1: Wrong image name → check registry URL
# Fix 2: Missing imagePullSecret
kubectl create secret docker-registry registry-creds \
  --docker-server=myregistry.io \
  --docker-username=$USER \
  --docker-password=$PASS
# Fix 3: Image doesn't exist → check tag

# CrashLoopBackOff — exits immediately on start
kubectl logs <pod> --previous   # Logs from previous crashed container
# Common causes: missing env var, bad config, DB not ready
# Quick test: override command to debug
kubectl run debug-test --image=myapp:v1 --command -- sleep 3600
kubectl exec -it debug-test -- sh   # Explore interactively

# Pending — not scheduled
kubectl describe pod <pod> | grep -A5 "Events:"
# "Insufficient cpu/memory" → scale cluster or reduce requests
# "Unschedulable" → check taints/tolerations
# "no matching node" → check nodeSelector labels

# OOMKilled — exit code 137
kubectl describe pod <pod> | grep -A3 "Last State:"
# Fix: increase memory limit
kubectl set resources deployment myapp --limits=memory=1Gi
```

---

### Service Connectivity Issues

```bash
# Can't reach service from another pod
kubectl exec -it test-pod -- curl http://myservice.mynamespace.svc.cluster.local
# If fails:

# Check 1: endpoints populated?
kubectl get endpoints myservice -n mynamespace
# Empty = no pods match selector

# Check 2: pod labels match service selector?
kubectl get svc myservice -o yaml | grep -A3 selector
kubectl get pods --show-labels | grep myapp

# Check 3: port config
kubectl get svc myservice -o yaml | grep -E "port:|targetPort:"
# service port → targetPort must match container port

# Check 4: NetworkPolicy blocking?
kubectl get networkpolicy -n mynamespace -o yaml | grep -A10 spec
```

---

### etcd / API Server Issues

```bash
# kubectl hangs or times out
kubectl cluster-info dump | grep -i error

# Check control plane components
kubectl get componentstatuses   # Deprecated but still useful
kubectl get pods -n kube-system | grep -v Running

# Check etcd health (on control plane node)
ETCDCTL_API=3 etcdctl endpoint health \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key
```

---

## Docker Issues

### Container Exits Immediately

```bash
# Check exit code
docker ps -a | grep myapp
# Status: Exited (1)

# Get logs
docker logs myapp --tail=50

# Common causes:
# Exit 1:   app error (missing config, db connection fail)
# Exit 127: command not found (bad CMD in Dockerfile)
# Exit 137: OOM killed (docker run --memory too low)

# Debug: override entrypoint
docker run -it --entrypoint sh myapp:latest
# Explore the container manually
```

---

### Docker Build Issues

```bash
# "COPY failed: file not found"
# Check .dockerignore — might be excluding the file
cat .dockerignore | grep myfile

# "apt-get: command not found"
# Wrong base image (alpine uses apk, not apt)
# FROM ubuntu → apt-get install
# FROM alpine → apk add

# Slow builds / no caching
# Problem: COPY . . before pip install → cache invalidates every build
# Fix: copy requirements.txt first, install, then copy source
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY . .    # Only this layer rebuilds when source changes

# "permission denied" errors in container
# Running as root but file owned by different user
docker run --user $(id -u):$(id -g) myapp:latest
```

---

## CI/CD Issues

### GitHub Actions Failures

```bash
# "Error: Process completed with exit code 1"
# Most common: no error message = test failure
# Solution: run locally first
# cd your-repo && act push   # Install: brew install act

# "Context deadline exceeded"
# Job timeout - increase:
jobs:
  build:
    timeout-minutes: 60   # Increase from default 6h

# "Resource not accessible by integration"
# Missing permissions
permissions:
  packages: write    # For pushing to GHCR
  contents: read
  id-token: write    # For OIDC

# "Error: HttpError: 403 Forbidden"
# GitHub token scopes
# Check: echo ${{ secrets.GITHUB_TOKEN }} | base64 -d | python3 -c "import sys,json;print(json.load(sys.stdin))"
```

---

### Terraform Issues

```bash
# "Error acquiring state lock"
# Someone else is running terraform
aws dynamodb scan --table-name terraform-state-lock
# If stale lock:
terraform force-unlock LOCK_ID

# "ResourceAlreadyExistsException"
# Resource exists but not in state
terraform import aws_s3_bucket.existing my-bucket-name

# "Provider produced inconsistent result"
# Usually timing issue — retry
terraform apply   # Run again

# State drift (manual changes made to infrastructure)
terraform refresh   # Update state to match reality
terraform plan      # Shows drift
```

---

## Database Issues

### PostgreSQL

```sql
-- Slow queries
SELECT query, mean_exec_time, calls
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 10;

-- Blocking queries
SELECT pid, usename, application_name, state, wait_event_type, wait_event, query
FROM pg_stat_activity
WHERE wait_event IS NOT NULL;

-- Kill blocking query
SELECT pg_terminate_backend(pid);

-- Table bloat (after many updates/deletes)
VACUUM ANALYZE my_table;   -- Or: VACUUM FULL my_table (locks table!)

-- Connection pool exhausted
SELECT count(*) FROM pg_stat_activity;
SHOW max_connections;
-- If close: increase max_connections in postgresql.conf
-- Better: use PgBouncer connection pooler
```

---

### Redis Issues

```bash
# Redis memory full (eviction happening)
redis-cli INFO memory | grep used_memory_human
redis-cli INFO stats | grep evicted_keys
# If evictions > 0: data being deleted! Increase maxmemory or fix code

# Slow commands (use SLOWLOG)
redis-cli SLOWLOG GET 10
# Shows commands taking > slowlog-log-slower-than (default: 10ms)

# Key expiry check
redis-cli TTL my-key       # -1 = no expiry, -2 = doesn't exist, N = seconds

# Flush all (DANGEROUS - only in dev)
redis-cli FLUSHALL

# Monitor all commands in real-time
redis-cli MONITOR   # Very verbose - use briefly
```

---

## Performance Issues

### High CPU

```bash
# Find CPU-hungry processes on a Kubernetes node
kubectl debug node/my-node -it --image=ubuntu -- bash
# Inside node shell:
top -b -n 1 | head -20
ps aux --sort=-%cpu | head -20

# CPU throttling (container hitting limit)
kubectl top pod myapp -n production
# Check: is containerized app being throttled?
cat /sys/fs/cgroup/cpu/cpu.stat | grep throttled_time

# Profiling (Python)
# Add to app temporarily:
# import cProfile
# with cProfile.Profile() as pr:
#     result = slow_function()
# pr.print_stats(sort='cumulative')
```

### Memory Leak

```bash
# Memory growing over time (pods older = more memory)
kubectl top pods -n production -l app=myapp
# Run every 5 minutes — compare

# Get memory profile (Python)
kubectl exec myapp-pod -- python3 -c "
import tracemalloc
tracemalloc.start()
# ... reproduce leak ...
snapshot = tracemalloc.take_snapshot()
for stat in snapshot.statistics('lineno')[:10]:
    print(stat)
"

# Go pprof
kubectl port-forward myapp-pod 6060:6060
go tool pprof http://localhost:6060/debug/pprof/heap
```

---

## Quick Reference: Fix Common Errors

| Error Message | Most Likely Cause | Quick Fix |
|--------------|------------------|-----------|
| `ImagePullBackOff` | Wrong registry URL or missing secret | Check image name + add imagePullSecret |
| `CrashLoopBackOff` | App crashes on startup | `kubectl logs --previous` |
| `Pending` | No suitable node | Check resources + taints |
| `OOMKilled (137)` | Memory limit too low | Increase memory limit |
| `connection refused` | Service not running | Check pods + endpoints |
| `no space left on device` | Disk full | Clean Docker images, logs |
| `exec format error` | Wrong CPU arch | Rebuild for linux/amd64 |
| `context deadline exceeded` | Timeout | Increase timeout + check network |
| `certificate has expired` | TLS cert expired | Renew cert (cert-manager) |
| `unauthorized` | Auth token expired | Refresh kubectl token |
