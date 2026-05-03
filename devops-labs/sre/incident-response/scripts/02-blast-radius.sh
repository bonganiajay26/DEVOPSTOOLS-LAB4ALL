#!/bin/bash
# =============================================================
# Script 02 — Blast Radius Assessment
# Answers: HOW BAD IS IT? Which services? How many users?
# Usage: bash 02-blast-radius.sh [--namespace production] [--prom http://localhost:9090]
# =============================================================

set -euo pipefail

NS="${1:-production}"
PROM="${PROMETHEUS_URL:-http://localhost:9090}"
BOLD='\033[1m'; RED='\033[0;31m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace|-n) NS="$2"; shift 2 ;;
    --prom)         PROM="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Helper: query Prometheus
prom_query() {
  local query="$1"
  curl -sf "$PROM/api/v1/query" \
    --data-urlencode "query=$query" 2>/dev/null | \
    python3 -c "
import json,sys
try:
    data = json.load(sys.stdin)
    results = data.get('data',{}).get('result',[])
    if results:
        print(results[0]['value'][1])
    else:
        print('no_data')
except:
    print('error')
" 2>/dev/null || echo "unavailable"
}

prom_query_all() {
  local query="$1"
  curl -sf "$PROM/api/v1/query" \
    --data-urlencode "query=$query" 2>/dev/null | \
    python3 -c "
import json,sys
try:
    data = json.load(sys.stdin)
    results = data.get('data',{}).get('result',[])
    for r in results:
        labels = ','.join(f'{k}={v}' for k,v in r['metric'].items() if k not in ['__name__','instance'])
        print(f'{labels}: {float(r[\"value\"][1]):.4f}')
except:
    pass
" 2>/dev/null || true
}

echo ""
echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║         BLAST RADIUS ASSESSMENT                  ║${NC}"
echo -e "${BOLD}${CYAN}║         Namespace: $NS                           ${NC}"
echo -e "${BOLD}${CYAN}║         $(date -u '+%H:%M UTC')                               ║${NC}"
echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════╝${NC}"

# ── 1. Pod health summary ─────────────────────────────────────
echo ""
echo -e "${BOLD}--- 1. Pod Health ($NS) ---${NC}"
TOTAL=$(kubectl get pods -n "$NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
RUNNING=$(kubectl get pods -n "$NS" --no-headers 2>/dev/null | grep " Running" | wc -l | tr -d ' ')
FAILING=$(kubectl get pods -n "$NS" --no-headers 2>/dev/null | grep -v "Running\|Completed" | wc -l | tr -d ' ')

echo "  Total pods:   $TOTAL"
echo "  Running:      $RUNNING"
if [ "$FAILING" -gt 0 ]; then
  echo -e "  ${RED}Failing:      $FAILING${NC}"
  echo ""
  echo "  Failing pods:"
  kubectl get pods -n "$NS" --no-headers 2>/dev/null | \
    grep -v "Running\|Completed" | \
    awk '{printf "    %-50s %s/%s\n", $1, $2, $3}' || true
else
  echo -e "  ${GREEN}Failing:      0 ✅${NC}"
fi

# ── 2. Error rate ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}--- 2. Error Rate (Prometheus) ---${NC}"
ERROR_RATE=$(prom_query "sum(rate(http_requests_total{namespace=\"$NS\",status=~\"5..\"}[2m]))")
TOTAL_RATE=$(prom_query "sum(rate(http_requests_total{namespace=\"$NS\"}[2m]))")

if [ "$ERROR_RATE" != "no_data" ] && [ "$TOTAL_RATE" != "no_data" ]; then
  ERROR_PCT=$(python3 -c "
e=float('$ERROR_RATE'); t=float('$TOTAL_RATE')
if t > 0:
    print(f'{e/t*100:.2f}')
else:
    print('0')
")
  echo "  Error rate:   ${ERROR_PCT}% (${ERROR_RATE}/s errors of ${TOTAL_RATE}/s total)"

  python3 << PYEOF
rate = float("$ERROR_PCT")
if rate > 10:
    print("\033[0;31m  SEVERITY: CRITICAL (>10% errors)\033[0m")
elif rate > 5:
    print("\033[1;33m  SEVERITY: HIGH (>5% errors)\033[0m")
elif rate > 1:
    print("\033[1;33m  SEVERITY: MODERATE (>1% errors)\033[0m")
else:
    print("\033[0;32m  SEVERITY: LOW (<1% errors)\033[0m")
PYEOF
else
  echo "  Prometheus unavailable — using kubectl fallback"
  echo "  Check manually: kubectl logs -l app=<service> -n $NS --since=5m | grep -c ERROR"
fi

# ── 3. Which services are affected? ───────────────────────────
echo ""
echo -e "${BOLD}--- 3. Affected Services ---${NC}"
echo "  Error rate by service (last 2 min):"
prom_query_all "sum(rate(http_requests_total{namespace=\"$NS\",status=~\"5..\"}[2m])) by (job)" | \
  while IFS=: read -r label val; do
    python3 -c "
val = float('$val'.strip())
if val > 0.1:
    print(f'  \033[0;31m  {\"$label\".strip()}: {val:.3f}/s ❌\033[0m')
else:
    print(f'    {\"$label\".strip()}: {val:.3f}/s ✅')
"
  done || echo "  Could not query Prometheus"

# ── 4. Which endpoints are worst? ─────────────────────────────
echo ""
echo -e "${BOLD}--- 4. Top Failing Endpoints ---${NC}"
prom_query_all "topk(5, sum(rate(http_requests_total{namespace=\"$NS\",status=~\"5..\"}[2m])) by (handler,method))" | \
  head -5 | while read line; do
    echo "  $line"
  done || echo "  Could not query Prometheus"

# ── 5. Dependency health check ────────────────────────────────
echo ""
echo -e "${BOLD}--- 5. Dependency Health ---${NC}"

# Database
DB_ENDPOINT=$(kubectl get svc -n database --no-headers 2>/dev/null | \
  grep -E "postgres|mysql|db" | awk '{print $1}' | head -1 || echo "")

if [ -n "$DB_ENDPOINT" ]; then
  READY_POD=$(kubectl get pod -n "$NS" -o name 2>/dev/null | head -1)
  if [ -n "$READY_POD" ]; then
    DB_STATUS=$(kubectl exec "$READY_POD" -n "$NS" -- \
      nc -zv "${DB_ENDPOINT}.database.svc.cluster.local" 5432 2>&1 | \
      grep -q "succeeded\|open" && echo "HEALTHY" || echo "UNREACHABLE")
    echo "  Database ($DB_ENDPOINT): $DB_STATUS"
  fi
else
  echo "  Database: (not found in 'database' namespace)"
fi

# Redis
REDIS_ENDPOINT=$(kubectl get svc -n "$NS" --no-headers 2>/dev/null | \
  grep redis | awk '{print $1}' | head -1 || echo "")
if [ -n "$REDIS_ENDPOINT" ]; then
  READY_POD=$(kubectl get pod -n "$NS" -o name 2>/dev/null | head -1)
  if [ -n "$READY_POD" ]; then
    REDIS_STATUS=$(kubectl exec "$READY_POD" -n "$NS" -- \
      redis-cli -h "$REDIS_ENDPOINT" ping 2>/dev/null | \
      grep -q "PONG" && echo "HEALTHY" || echo "UNREACHABLE")
    echo "  Redis ($REDIS_ENDPOINT): $REDIS_STATUS"
  fi
fi

# ── 6. Recent deployments ─────────────────────────────────────
echo ""
echo -e "${BOLD}--- 6. Recent Deployments (last 2 hours) ---${NC}"
echo "  (Check if error start correlates with a deploy)"
kubectl rollout history deployment -n "$NS" 2>/dev/null | \
  grep -v "^REVISION\|^deployment" | \
  awk '{print "  "$0}' | tail -10 || echo "  No deployments found"

# ── 7. Node pressure ──────────────────────────────────────────
echo ""
echo -e "${BOLD}--- 7. Node Resource Pressure ---${NC}"
kubectl describe nodes 2>/dev/null | grep -A1 "MemoryPressure\|DiskPressure" | \
  grep -v "^--" | awk '{print "  "$0}' || echo "  kubectl describe nodes failed"

echo ""
echo -e "${BOLD}--- 8. Recent Warning Events ---${NC}"
kubectl get events -n "$NS" --field-selector type=Warning \
  --sort-by='.lastTimestamp' 2>/dev/null | tail -10 | \
  awk '{print "  "$0}' || echo "  No events"

# ── Summary ───────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}═══ BLAST RADIUS SUMMARY ═══${NC}"
echo ""
echo "  Namespace:    $NS"
echo "  Pods failing: $FAILING / $TOTAL"
echo "  Error rate:   ${ERROR_PCT:-unknown}%"
echo "  Time:         $(date -u '+%H:%M UTC')"
echo ""
echo "  Next steps:"
echo "    → Check recent deployments first: kubectl rollout history deployment -A"
echo "    → Diagnose: bash 03-diagnose.sh --namespace $NS"
echo "    → Rollback (if deploy suspected): bash 04-safe-rollback.sh <deploy> $NS"
