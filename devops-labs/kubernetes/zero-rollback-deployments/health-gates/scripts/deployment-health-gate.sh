#!/bin/bash
# =============================================================
# Deployment Health Gate
# Runs post-deploy: blocks the pipeline if metrics degrade
# within 5 minutes of deployment.
#
# This is the ArgoCD sync hook + standalone script equivalent of
# Harness's "deployment health verification" stage.
#
# Usage:
#   bash deployment-health-gate.sh \
#     --deployment myapp \
#     --namespace production \
#     --window 300 \
#     --error-threshold 0.02 \
#     --latency-threshold 500
# =============================================================

set -euo pipefail

DEPLOY="myapp"
NS="production"
WINDOW=300                  # Seconds to monitor post-deploy
ERROR_THRESHOLD="0.02"      # 2% error rate = fail
LATENCY_P99_MS="500"        # p99 > 500ms = fail
PROM="${PROMETHEUS_URL:-http://localhost:9090}"
CHECK_INTERVAL=30           # Check every 30 seconds
ROLLBACK_ON_FAIL=true

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; CYAN='\033[0;36m'; NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --deployment)         DEPLOY="$2";           shift 2 ;;
    --namespace)          NS="$2";               shift 2 ;;
    --window)             WINDOW="$2";           shift 2 ;;
    --error-threshold)    ERROR_THRESHOLD="$2";  shift 2 ;;
    --latency-threshold)  LATENCY_P99_MS="$2";   shift 2 ;;
    --no-rollback)        ROLLBACK_ON_FAIL=false; shift ;;
    *) shift ;;
  esac
done

# ── Prometheus query helper ───────────────────────────────────
prom_scalar() {
  local query="$1"
  curl -sf "$PROM/api/v1/query" \
    --data-urlencode "query=$query" 2>/dev/null | \
    python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
    results = d.get('data',{}).get('result',[])
    print(results[0]['value'][1] if results else 'no_data')
except:
    print('error')
" 2>/dev/null || echo "unavailable"
}

# ── Record pre-deploy baseline ────────────────────────────────
BASELINE_ERROR=$(prom_scalar \
  "sum(rate(http_requests_total{namespace=\"$NS\",status=~\"5..\"}[5m]))/sum(rate(http_requests_total{namespace=\"$NS\"}[5m]))")
BASELINE_LATENCY=$(prom_scalar \
  "histogram_quantile(0.99,sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\"}[5m]))by(le))*1000")

echo ""
echo -e "${BOLD}╔═══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   DEPLOYMENT HEALTH GATE                         ║${NC}"
echo -e "${BOLD}║   Deployment: $DEPLOY ($NS)                  ║${NC}"
echo -e "${BOLD}║   Monitor window: ${WINDOW}s                      ║${NC}"
echo -e "${BOLD}╚═══════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Pre-deploy baseline:"
echo "    Error rate: $BASELINE_ERROR"
echo "    p99 latency: ${BASELINE_LATENCY}ms"
echo "  Thresholds:"
echo "    Max error rate: $ERROR_THRESHOLD (${ERROR_THRESHOLD})"
echo "    Max p99 latency: ${LATENCY_P99_MS}ms"
echo ""

# ── Monitor loop ──────────────────────────────────────────────
TOTAL_CHECKS=$((WINDOW / CHECK_INTERVAL))
FAILED_CHECKS=0
MAX_CONSECUTIVE_FAILS=3
CONSECUTIVE_FAILS=0
DEPLOY_START=$(date -u '+%H:%M:%S')

info "Starting health gate monitoring at $DEPLOY_START..."
info "Will check every ${CHECK_INTERVAL}s for ${WINDOW}s total (${TOTAL_CHECKS} checks)"
echo ""

for i in $(seq 1 $TOTAL_CHECKS); do
  sleep $CHECK_INTERVAL

  # Get current metrics
  CURRENT_ERROR=$(prom_scalar \
    "sum(rate(http_requests_total{namespace=\"$NS\",status=~\"5..\"}[2m]))/sum(rate(http_requests_total{namespace=\"$NS\"}[2m]))")
  CURRENT_LATENCY=$(prom_scalar \
    "histogram_quantile(0.99,sum(rate(http_request_duration_seconds_bucket{namespace=\"$NS\"}[2m]))by(le))*1000")

  # Check thresholds
  CHECK_RESULT=$(python3 << PYEOF
error    = float("$CURRENT_ERROR".replace('no_data','0').replace('unavailable','0').replace('error','0') or '0')
latency  = float("$CURRENT_LATENCY".replace('no_data','0').replace('unavailable','0').replace('error','0') or '0')
err_thr  = float("$ERROR_THRESHOLD")
lat_thr  = float("$LATENCY_P99_MS")

issues = []
if error > err_thr:
    issues.append(f"error_rate={error:.4f} > threshold={err_thr}")
if latency > 0 and latency > lat_thr:
    issues.append(f"p99_latency={latency:.0f}ms > threshold={lat_thr}ms")

status = "FAIL" if issues else "OK"
details = " | ".join(issues) if issues else f"error={error:.4f} latency={latency:.0f}ms"
print(f"{status}|{details}")
PYEOF
  )

  STATUS="${CHECK_RESULT%%|*}"
  DETAILS="${CHECK_RESULT##*|}"
  TIMESTAMP=$(date -u '+%H:%M:%S')

  if [ "$STATUS" = "OK" ]; then
    CONSECUTIVE_FAILS=0
    echo -e "  [${TIMESTAMP}] Check $i/$TOTAL_CHECKS: ${GREEN}OK${NC} — $DETAILS"
  else
    CONSECUTIVE_FAILS=$((CONSECUTIVE_FAILS + 1))
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
    echo -e "  [${TIMESTAMP}] Check $i/$TOTAL_CHECKS: ${RED}FAIL${NC} ($CONSECUTIVE_FAILS consecutive) — $DETAILS"

    if [ $CONSECUTIVE_FAILS -ge $MAX_CONSECUTIVE_FAILS ]; then
      echo ""
      fail "Health gate FAILED: $MAX_CONSECUTIVE_FAILS consecutive failures detected"
      echo ""
      echo "  Issue: $DETAILS"
      echo "  Deployment: $DEPLOY in $NS"
      echo "  Failed at: $TIMESTAMP"

      if $ROLLBACK_ON_FAIL; then
        warn "Auto-rolling back $DEPLOY in $NS..."
        kubectl rollout undo deployment/"$DEPLOY" -n "$NS"
        kubectl rollout status deployment/"$DEPLOY" -n "$NS" --timeout=3m
        echo ""
        echo -e "${RED}ROLLBACK EXECUTED${NC}"
        echo "  Update your incident channel: deployment $DEPLOY auto-rolled back"
        echo "  Run diagnosis: bash ../../sre/incident-response/scripts/01-diagnose.sh"
      else
        warn "Rollback disabled (--no-rollback flag). Manual action required."
      fi

      exit 1
    fi
  fi
done

# ── Final summary ─────────────────────────────────────────────
echo ""
PASS_RATE=$(python3 -c "print(round((${TOTAL_CHECKS}-${FAILED_CHECKS})/${TOTAL_CHECKS}*100,1))")
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   HEALTH GATE PASSED                             ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Deployment:  $DEPLOY ($NS)"
echo "  Duration:    ${WINDOW}s monitored"
echo "  Pass rate:   ${PASS_RATE}% (${FAILED_CHECKS}/${TOTAL_CHECKS} checks failed)"
echo "  Start time:  $DEPLOY_START"
echo "  End time:    $(date -u '+%H:%M:%S')"
echo ""
info "Deployment is healthy. Canary can proceed to next step."
