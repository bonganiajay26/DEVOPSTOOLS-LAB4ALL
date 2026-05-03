#!/bin/bash
# =============================================================
# Script 02 — Memory Profile & Pattern Detection
# Queries Prometheus to determine: LEAK vs SPIKE vs WRONG_LIMIT
# Usage:  bash 02-memory-profile.sh <pod-name> <namespace> [prom-url]
# =============================================================

set -euo pipefail

POD="${1:-}"
NS="${2:-production}"
PROM="${3:-http://localhost:9090}"

if [ -z "$POD" ]; then
  echo "Usage: $0 <pod-name> <namespace> [prometheus-url]"
  exit 1
fi

# Auto-detect container name
CONTAINER=$(kubectl get pod "$POD" -n "$NS" \
  -o jsonpath='{.spec.containers[0].name}' 2>/dev/null || echo "")

echo "=== Memory Profile: $POD ($NS) ==="
echo "    Container: $CONTAINER"
echo "    Prometheus: $PROM"
echo ""

# Helper: query Prometheus
prom_query() {
  local query="$1"
  local result
  result=$(curl -sf "$PROM/api/v1/query" \
    --data-urlencode "query=$query" 2>/dev/null) || { echo "null"; return; }
  echo "$result" | python3 -c "
import json, sys
data = json.load(sys.stdin)
results = data.get('data', {}).get('result', [])
if results:
    print(results[0]['value'][1])
else:
    print('no_data')
" 2>/dev/null || echo "error"
}

# Port-forward Prometheus if needed
if ! curl -sf "$PROM/-/ready" &>/dev/null; then
  echo "Prometheus not reachable at $PROM"
  echo "Starting port-forward..."
  kubectl port-forward svc/prometheus-operated 9090:9090 -n monitoring &
  PF_PID=$!
  sleep 3
  PROM="http://localhost:9090"
  trap "kill $PF_PID 2>/dev/null" EXIT
fi

echo "--- Current Memory Metrics ---"
echo ""

# Current working set
CURRENT_MEM=$(prom_query \
  "container_memory_working_set_bytes{pod=\"$POD\",container=\"$CONTAINER\"}")
echo "  Working set (now):      $CURRENT_MEM bytes"

# Memory limit
MEM_LIMIT_RAW=$(prom_query \
  "container_spec_memory_limit_bytes{pod=\"$POD\",container=\"$CONTAINER\"}")
echo "  Limit:                  $MEM_LIMIT_RAW bytes"

# Usage as % of limit
if [ "$CURRENT_MEM" != "no_data" ] && [ "$MEM_LIMIT_RAW" != "no_data" ]; then
  PCT=$(python3 -c "print(round(float('$CURRENT_MEM')/float('$MEM_LIMIT_RAW')*100,1))" 2>/dev/null || echo "?")
  echo "  Usage % of limit:       $PCT%"
  if python3 -c "exit(0 if float('$PCT') > 80 else 1)" 2>/dev/null; then
    echo "  WARNING: Over 80% of limit — OOMKill imminent!"
  fi
fi

echo ""
echo "--- Memory Growth Analysis (last 1h) ---"
echo ""

# Rate of memory growth (bytes/second over last 30min)
GROWTH_RATE=$(prom_query \
  "deriv(container_memory_working_set_bytes{pod=\"$POD\",container=\"$CONTAINER\"}[30m])")
echo "  Memory growth rate:     $GROWTH_RATE bytes/sec"

if [ "$GROWTH_RATE" != "no_data" ] && [ "$GROWTH_RATE" != "error" ]; then
  HOURLY=$(python3 -c "r=float('$GROWTH_RATE'); print(f'{r*3600/1024/1024:.1f} MB/hour')" 2>/dev/null || echo "?")
  echo "  Hourly growth:          $HOURLY"

  # Classify pattern
  echo ""
  echo "--- Pattern Classification ---"
  python3 << PYEOF
rate = float("$GROWTH_RATE")
hourly_mb = rate * 3600 / 1024 / 1024

if hourly_mb > 10:
    print("  PATTERN: MEMORY LEAK (growing >10MB/hour)")
    print("  Evidence: Steady memory increase detected")
    print("  Action:   Profile the application to find the leak source")
    print("            Temporary: increase limit + add 80% alert")
    print("            Permanent: fix the leak in code")
elif hourly_mb > 2:
    print("  PATTERN: POSSIBLE SLOW LEAK (growing 2-10MB/hour)")
    print("  Evidence: Gradual memory increase, may crash in hours/days")
    print("  Action:   Monitor for 24h, profile if trend continues")
elif hourly_mb > 0:
    print("  PATTERN: NORMAL GROWTH (growing <2MB/hour)")
    print("  Evidence: Typical memory behavior, may just need higher limit")
    print("  Action:   Use VPA recommendations to right-size the limit")
else:
    print("  PATTERN: STABLE / SPIKE (not a gradual leak)")
    print("  Evidence: Memory is stable now — crash was likely a spike")
    print("  Action:   Correlate with traffic/request patterns")
    print("            Add HPA to handle load spikes")
PYEOF
fi

echo ""
echo "--- OOM Event History ---"

# OOM restart count over time
OOM_RESTARTS=$(prom_query \
  "increase(kube_pod_container_status_restarts_total{pod=\"$POD\",container=\"$CONTAINER\"}[24h])")
echo "  Restarts in last 24h:   $OOM_RESTARTS"

echo ""
echo "--- Recommended Prometheus Queries to Run in Grafana ---"
echo ""
cat << 'QUERIES'
  # 1. Memory trend over 24h (paste in Prometheus UI or Grafana)
  container_memory_working_set_bytes{pod="POD_NAME", container="CONTAINER_NAME"}

  # 2. Memory as % of limit
  container_memory_working_set_bytes{pod="POD_NAME"}
    / container_spec_memory_limit_bytes{pod="POD_NAME"} * 100

  # 3. Detect all pods near OOM limit in production
  (
    container_memory_working_set_bytes{namespace="production"}
    / container_spec_memory_limit_bytes{namespace="production"}
  ) > 0.8

  # 4. Memory leak detection — pods growing > 5MB/hour
  deriv(container_memory_working_set_bytes{namespace="production"}[30m]) * 3600
    > 5*1024*1024

  # 5. OOM events across all namespaces
  increase(kube_pod_container_status_restarts_total[1h])
    * on(pod,namespace) kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}
QUERIES

echo ""
echo "=== Next Step ==="
echo "  Apply VPA recommendations: bash 04-rightsize.sh $POD $NS"
echo "  Set OOM alert:             kubectl apply -f ../prometheus/oom-alert-rules.yaml"
