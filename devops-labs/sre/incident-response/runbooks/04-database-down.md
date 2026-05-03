# Runbook 04 — Database Down / Unreachable

**Alert**: `PostgresDown` OR apps returning 500s with `connection refused`  
**Severity**: SEV1 (database is the most critical dependency)  
**Estimated resolution**: 5 min (if connection issue) | 30 min (if DB crash) | 2h (if data issue)

---

## Immediate Check (30 seconds)

```bash
# Is the database pod running?
kubectl get pods -n database
# postgres-0   0/1   CrashLoopBackOff  ← DATABASE IS DOWN

# Can the application reach the database?
kubectl exec -it \
  $(kubectl get pod -l app=api-service -n production -o name | head -1) \
  -n production -- \
  nc -zv postgres.database.svc.cluster.local 5432
# Connection refused = DB down
# Connected = DB up but app has issues

# Is the PVC healthy?
kubectl get pvc -n database
# If Bound → storage OK. If Pending → storage issue.
```

---

## Scenario A: PostgreSQL pod is down (CrashLoopBackOff)

```bash
# Check why postgres crashed
kubectl logs postgres-0 -n database --previous | tail -50
kubectl describe pod postgres-0 -n database | grep -A15 "Events:"

# Common messages and fixes:
# "could not translate host name" → DNS issue in container
# "data directory has wrong ownership" → file permissions
# "lock file exists" → unclean shutdown → delete postmaster.pid
# "database files are incompatible" → version mismatch
# "out of memory" → OOMKill, increase memory limit

# Emergency: delete pod (StatefulSet recreates it with same PVC)
kubectl delete pod postgres-0 -n database
kubectl get pod postgres-0 -n database -w   # Watch it restart

# Verify after restart
sleep 10
kubectl exec -it postgres-0 -n database -- pg_isready -U postgres
```

---

## Scenario B: Database is up but connection pool exhausted

```bash
# Check connection count vs max
kubectl exec -it postgres-0 -n database -- \
  psql -U postgres -c "
    SELECT count(*) AS active,
           (SELECT setting::int FROM pg_settings WHERE name='max_connections') AS max,
           round(count(*)::numeric /
             (SELECT setting::int FROM pg_settings WHERE name='max_connections') * 100, 1) AS pct
    FROM pg_stat_activity;"

# If > 80% → emergency connection cleanup
kubectl exec -it postgres-0 -n database -- \
  psql -U postgres -c "
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE state IN ('idle', 'idle in transaction')
    AND query_start < now() - interval '5 minutes'
    AND pid <> pg_backend_pid();"

# Prevent recurrence: rolling restart app (closes app-side connections)
kubectl rollout restart deployment/api-service -n production
```

---

## Scenario C: Disk full on database node

```bash
# Check disk usage on the postgres PVC
kubectl exec -it postgres-0 -n database -- df -h /var/lib/postgresql/data

# If disk > 90%:
# Option 1: Clear old WAL logs (safe)
kubectl exec -it postgres-0 -n database -- \
  psql -U postgres -c "SELECT pg_switch_wal();"

# Option 2: VACUUM (reclaim space from dead rows)
kubectl exec -it postgres-0 -n database -- \
  psql -U postgres -c "VACUUM FULL ANALYZE;"   # WARNING: locks tables

# Option 3: Expand PVC (if StorageClass supports it)
kubectl patch pvc postgres-data-postgres-0 -n database \
  -p '{"spec":{"resources":{"requests":{"storage":"200Gi"}}}}'
```

---

## Scenario D: Database unreachable but pod is running

```bash
# Check NetworkPolicy
kubectl get networkpolicy -n database
# If there's a policy: verify it allows traffic from production namespace

# Check Service endpoints
kubectl get endpoints postgres -n database
# If empty: selector mismatch

# Check pod readiness
kubectl describe pod postgres-0 -n database | grep -A10 "Conditions:"

# DNS test from application pod
kubectl exec -it \
  $(kubectl get pod -l app=api-service -n production -o name | head -1) \
  -n production -- \
  nslookup postgres.database.svc.cluster.local
```

---

## Enable Application Degraded Mode (while DB is being fixed)

```bash
# If the application supports it, enable read-only / cached mode
kubectl set env deployment/api-service \
  DB_MODE=degraded \
  USE_CACHE=true \
  -n production
# Users see stale data but no 500s

# Revert after DB is restored
kubectl set env deployment/api-service \
  DB_MODE=normal \
  USE_CACHE=false \
  -n production
```

---

## Escalation

- Database down > 5 min: Page DBA immediately
- Data corruption suspected: Page DBA + VP Engineering
- Data loss possible: Page DBA + VP + Legal
