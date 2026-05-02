# Lab 02: Performance Debugging — High Latency and Slow Queries

**Difficulty**: Advanced | **Time**: 60 minutes  
**Goal**: Diagnose and fix performance issues using profiling, distributed tracing, and query analysis.

---

## Scenario

Your API's p99 latency jumped from 120ms to 2.3 seconds after Tuesday's deploy. Users are complaining. No errors, just slow.

---

## Part 1: Establish the Baseline

```bash
# Step 1: Confirm the latency issue
kubectl port-forward svc/api-service 8080:80 -n production &
sleep 2

# Measure p99 with vegeta
echo "GET http://localhost:8080/api/checkout" | \
  vegeta attack -rate=50/s -duration=30s | \
  vegeta report

# Or with hey
hey -n 1000 -c 50 http://localhost:8080/api/checkout

# Check Prometheus
kubectl port-forward svc/prometheus 9090:9090 -n monitoring &
# Query: histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))
```

---

## Part 2: Identify Which Component is Slow

```bash
# Use distributed tracing if available (Jaeger/Tempo)
# Otherwise: time each component manually

# Test: is it the API or the database?
kubectl exec -it -n production $(kubectl get pod -l app=api -o name | head -1) -- \
  python3 -c "
import time, psycopg2, os

# Test DB latency
start = time.time()
conn = psycopg2.connect(os.environ['DATABASE_URL'])
cursor = conn.cursor()
cursor.execute('SELECT 1')
result = cursor.fetchone()
conn.close()
print(f'DB ping: {(time.time()-start)*1000:.1f}ms')
"

# Test: is it a specific endpoint?
for endpoint in /api/checkout /api/products /api/users; do
  echo -n "$endpoint: "
  curl -s -w "%{time_total}s\n" -o /dev/null http://localhost:8080$endpoint
done

# Check N+1 query pattern (common culprit)
kubectl logs -n production -l app=api --tail=200 | \
  grep -E "SELECT|query" | \
  sort | uniq -c | sort -rn | head -20
```

---

## Part 3: Database Query Analysis

```bash
# Connect to PostgreSQL and check slow queries
kubectl exec -it -n production postgres-0 -- psql -U appuser appdb << 'EOF'
-- Enable query stats (may already be enabled)
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Top 10 slowest queries
SELECT
    round(total_exec_time::numeric, 2) AS total_time_ms,
    calls,
    round(mean_exec_time::numeric, 2) AS avg_time_ms,
    round((100 * total_exec_time / sum(total_exec_time) OVER ())::numeric, 2) AS pct_total,
    query
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 10;

-- Check for missing indexes
SELECT
    schemaname,
    tablename,
    attname,
    n_distinct,
    correlation
FROM pg_stats
WHERE tablename IN (
    SELECT relname FROM pg_stat_user_tables
    WHERE seq_scan > idx_scan
    AND n_live_tup > 10000
)
ORDER BY seq_scan DESC;

-- Show current long-running queries
SELECT
    pid,
    now() - query_start AS duration,
    query,
    state
FROM pg_stat_activity
WHERE state != 'idle'
AND query_start < now() - interval '1 second'
ORDER BY duration DESC;
EOF
```

---

## Part 4: Python Application Profiling

```bash
# Add profiling endpoint to the app (temporarily)
cat > /tmp/profile_patch.py << 'EOF'
import cProfile
import pstats
import io
from functools import wraps
from flask import Flask, request, jsonify

def profile_endpoint(f):
    """Decorator to profile a Flask endpoint."""
    @wraps(f)
    def wrapper(*args, **kwargs):
        if not request.args.get('profile'):
            return f(*args, **kwargs)
        
        profiler = cProfile.Profile()
        result = profiler.runcall(f, *args, **kwargs)
        
        # Get top 20 functions by cumulative time
        stream = io.StringIO()
        stats = pstats.Stats(profiler, stream=stream)
        stats.sort_stats('cumulative')
        stats.print_stats(20)
        
        print(stream.getvalue())  # Logs to container stdout
        return result
    return wrapper

# Apply to slow endpoint:
# @app.route('/api/checkout')
# @profile_endpoint
# def checkout():
#     ...
EOF

# Copy profile script to the running pod
kubectl cp /tmp/profile_patch.py \
  $(kubectl get pod -l app=api -n production -o name | head -1 | cut -d/ -f2):/tmp/ \
  -n production

# Trigger profiled request
curl "http://localhost:8080/api/checkout?profile=true"

# Check logs for profile output
kubectl logs -n production -l app=api --tail=100 | grep -A 30 "cumtime"
```

---

## Part 5: Memory Leak Investigation

```bash
# Check memory over time
kubectl top pod -n production -l app=api
kubectl top pod -n production -l app=api    # Run again after 5 minutes

# If memory keeps growing → memory leak
# Common Python causes: unclosed connections, circular references, global caches

# Check connection pool
kubectl exec -it -n production $(kubectl get pod -l app=api -o name | head -1) -- \
  python3 -c "
import gc
import psutil
import os

process = psutil.Process(os.getpid())
print(f'Memory: {process.memory_info().rss / 1024 / 1024:.1f} MB')
print(f'Open files: {len(process.open_files())}')
print(f'Connections: {len(process.connections())}')
print(f'Threads: {process.num_threads()}')

# Count objects by type
gc.collect()
from collections import Counter
obj_counts = Counter(type(obj).__name__ for obj in gc.get_objects())
for name, count in obj_counts.most_common(10):
    print(f'{name}: {count}')
"
```

---

## Part 6: Systematic Fix Process

```bash
# Once root cause found, apply fix:

# Case A: Missing database index
kubectl exec -it -n production postgres-0 -- psql -U appuser appdb << 'EOF'
-- Add missing index (use CONCURRENTLY to avoid table lock)
CREATE INDEX CONCURRENTLY idx_orders_user_id_created
    ON orders(user_id, created_at DESC);

-- Verify index is used
EXPLAIN ANALYZE SELECT * FROM orders
WHERE user_id = '123' ORDER BY created_at DESC LIMIT 10;
-- Should show: Index Scan (not Seq Scan)
EOF

# Case B: N+1 query - add eager loading in ORM
# SQLAlchemy:
# Bad:  orders = Order.query.all(); [o.user for o in orders]  <- N+1
# Good: orders = Order.query.options(joinedload(Order.user)).all()

# Case C: Slow external API call - add caching
# Add Redis caching to slow endpoint:
# @cache.cached(timeout=60, key_prefix='checkout_%s')
# def get_checkout_data(user_id):
#     return expensive_external_api_call(user_id)

# After fix: verify latency improved
hey -n 1000 -c 50 http://localhost:8080/api/checkout

# Document the fix
cat << 'EOF' > post-incident-notes.md
## Performance Issue — 2024-01-15

**Symptom**: p99 latency 120ms → 2.3s after deploy

**Root cause**: Missing database index on orders(user_id, created_at)
Deploy on 2024-01-14 added a new query pattern that triggered full table scan
on orders table (2.3M rows). Average query time: 1.8s.

**Fix**: Added `CREATE INDEX CONCURRENTLY idx_orders_user_id_created`
Latency returned to 95ms (p99) within 2 minutes of index creation.

**Prevention**:
- Add EXPLAIN ANALYZE to PR checklist for any new SQL queries
- Add slow query alert: pg_stat_statements avg_time > 100ms
- Performance test in staging before production deploy
EOF
```

---

## What You Learned

- [x] Systematic performance investigation process
- [x] Database slow query analysis with pg_stat_statements
- [x] Python application profiling with cProfile
- [x] Memory leak detection with psutil and gc module
- [x] Missing index detection and resolution
- [x] Documenting performance incidents for future reference
