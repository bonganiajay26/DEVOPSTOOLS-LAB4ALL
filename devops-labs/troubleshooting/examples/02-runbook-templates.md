# Example 02: Production Runbook Templates

## Runbook: High CPU Usage

**Alert**: `NodeHighCPU` — Node CPU > 90% for 10 minutes  
**Severity**: Warning → Critical if > 95%

### Immediate Actions (< 5 min)
```bash
# 1. Identify top CPU consumers
kubectl top pods -A --sort-by=cpu | head -20

# 2. Check if it's a single runaway pod
kubectl top pod <top-pod> --containers -n <namespace>

# 3. Identify the process inside the pod
kubectl exec -it <pod> -n <namespace> -- top -b -n1 | head -20
```

### Investigation
```bash
# Check if CPU is CPU-throttled (hitting limits)
kubectl describe pod <pod> -n <namespace> | grep -A10 "Limits:"

# Check for recent deployments
kubectl rollout history deployment -n <namespace>

# Prometheus query to understand trend:
# rate(container_cpu_usage_seconds_total{pod="<pod>"}[5m])
```

### Resolution
| If... | Then... |
|-------|---------|
| Single pod runaway | `kubectl delete pod <pod>` (restart) |
| All pods high CPU | Scale up: `kubectl scale deployment <app> --replicas=10` |
| Recent deploy | `kubectl rollout undo deployment/<app>` |
| CPU limit too low | `kubectl set resources deployment/<app> --limits=cpu=2` |
| Genuine traffic spike | Scale HPA maxReplicas temporarily |

---

## Runbook: Database Connection Exhaustion

**Alert**: `PostgresHighConnections` — Connection count > 80%  
**Severity**: Warning at 80%, Critical at 95%

### Immediate Actions
```bash
# Check current connections
kubectl exec -it postgres-0 -n database -- \
  psql -U postgres -c "SELECT count(*) FROM pg_stat_activity;"

# See connections by application
kubectl exec -it postgres-0 -n database -- \
  psql -U postgres -c "
    SELECT application_name, count(*) 
    FROM pg_stat_activity 
    GROUP BY application_name 
    ORDER BY count DESC;"
```

### Investigation
```bash
# Find long-running queries (might be holding connections)
kubectl exec -it postgres-0 -n database -- \
  psql -U postgres -c "
    SELECT pid, now() - query_start AS duration, query
    FROM pg_stat_activity
    WHERE state = 'active'
    AND query_start < now() - interval '5 minutes'
    ORDER BY duration DESC;"

# Check for idle-in-transaction (connection leak)
kubectl exec -it postgres-0 -n database -- \
  psql -U postgres -c "
    SELECT count(*), state
    FROM pg_stat_activity
    GROUP BY state;"
```

### Resolution
```bash
# Kill idle connections
kubectl exec -it postgres-0 -n database -- \
  psql -U postgres -c "
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE state = 'idle'
    AND query_start < now() - interval '30 minutes';"

# Reduce connection pressure: rolling restart of app
kubectl rollout restart deployment/<app> -n production

# Long-term: implement PgBouncer connection pooling
```

---

## Runbook: Certificate Expiry

**Alert**: `CertificateExpiryWarning` — TLS cert expires in < 14 days  
**Severity**: Warning (14 days), Critical (3 days)

### Check Status
```bash
# List all certificates
kubectl get certificates -A

# Check specific cert
kubectl describe certificate my-cert -n production
# Look for: "Conditions: Ready=True" and "Not After"

# Check cert-manager pods
kubectl get pods -n cert-manager
kubectl logs -n cert-manager -l app=cert-manager --tail=50 | grep -i error
```

### Manual Renewal
```bash
# Force cert-manager to renew immediately
kubectl annotate certificate my-cert -n production \
  cert-manager.io/issue-temporary-certificate="true"

# Delete the certificate resource (cert-manager recreates it)
kubectl delete certificate my-cert -n production
# cert-manager will create a new one automatically

# Verify renewal in progress
kubectl describe certificaterequest -n production | head -30
```

### Verify
```bash
# Check the TLS secret
kubectl get secret my-cert-tls -n production \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | \
  openssl x509 -noout -dates
# Should show future expiry date
```

---

## Runbook: Service Degradation (Partial Outage)

**Alert**: `SLOAvailabilityBudgetBurning` or elevated error rate  
**Severity**: SEV-2 (degraded, not down)

### 1. Assess Blast Radius (2 min)
```bash
# Which endpoints are affected?
kubectl logs -l app=api -n production --tail=100 | \
  grep "ERROR\|5[0-9][0-9]" | \
  awk '{print $NF}' | sort | uniq -c | sort -rn | head -10

# Error rate per endpoint (PromQL):
# sum(rate(http_requests_total{status=~"5.."}[5m])) by (handler)
#   / sum(rate(http_requests_total[5m])) by (handler) * 100
```

### 2. Check Dependencies
```bash
# Database healthy?
kubectl exec -it -n production \
  $(kubectl get pod -l app=api -n production -o name | head -1) -- \
  python3 -c "
import psycopg2, os
conn = psycopg2.connect(os.environ['DATABASE_URL'])
cursor = conn.cursor()
cursor.execute('SELECT 1')
print('DB: OK', cursor.fetchone())
conn.close()
" 2>&1 || echo "DB CHECK FAILED"

# Redis healthy?
kubectl exec -it -n production \
  $(kubectl get pod -l app=api -n production -o name | head -1) -- \
  python3 -c "
import redis, os
r = redis.from_url(os.environ['REDIS_URL'])
r.ping()
print('Redis: OK')
" 2>&1 || echo "REDIS CHECK FAILED"

# External API (if applicable)
curl -sf https://api.external-service.com/health || echo "EXTERNAL API DOWN"
```

### 3. Rapid Fixes
```bash
# If recent deployment → rollback
kubectl rollout undo deployment/api -n production

# If memory leak → rolling restart
kubectl rollout restart deployment/api -n production

# If traffic spike → scale up
kubectl scale deployment/api --replicas=20 -n production

# If feature causing issues → disable via feature flag
kubectl set env deployment/api FEATURE_X_ENABLED=false -n production
```

---

## Runbook: Node Disk Pressure

**Alert**: `DiskAlmostFull` — Node disk > 85%  
**Severity**: Warning at 85%, Critical at 95%

```bash
# SSH to the node or use kubectl debug
kubectl debug node/<node-name> -it --image=ubuntu

# Inside the debug shell (chroot to host):
chroot /host

# Find what's using disk
df -h
du -sh /var/lib/containerd/*  # Container images and layers
du -sh /var/log/*              # Logs

# Clean up
# 1. Remove unused container images
crictl rmi --prune

# 2. Clean up old logs
journalctl --vacuum-size=500M
find /var/log -name "*.gz" -mtime +7 -delete

# 3. Remove old container layers
crictl rm $(crictl ps -aq)  # Remove stopped containers
crictl rmi $(crictl images -q)  # Remove unused images
```
