#!/bin/bash
# =============================================================
# Blue/Green Traffic Switch
# Promotes green to production with smoke tests and auto-rollback.
#
# Usage:
#   bash traffic-switch.sh promote  --namespace production --image myapp:v2.4.0
#   bash traffic-switch.sh rollback --namespace production
# =============================================================

set -euo pipefail

COMMAND="${1:-help}"
NS="production"
IMAGE=""
SERVICE="myapp"
PROM_URL="${PROMETHEUS_URL:-http://localhost:9090}"
SMOKE_URL="${SMOKE_URL:-https://api.company.com}"
PREVIEW_URL="${PREVIEW_URL:-https://preview.company.com}"
HEALTH_WINDOW="${HEALTH_WINDOW:-300}"   # Seconds to monitor after switch

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; CYAN='\033[0;36m'; NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

# ── Get active slot ───────────────────────────────────────────
get_active_slot() {
  kubectl get svc "$SERVICE" -n "$NS" \
    -o jsonpath='{.spec.selector.slot}' 2>/dev/null || echo "blue"
}

get_inactive_slot() {
  local active; active=$(get_active_slot)
  [ "$active" = "blue" ] && echo "green" || echo "blue"
}

# ── Error rate check ──────────────────────────────────────────
check_error_rate() {
  local slot="$1"
  local threshold="${2:-0.01}"   # 1% error rate threshold

  local rate
  rate=$(curl -sf "$PROM_URL/api/v1/query" \
    --data-urlencode "query=sum(rate(http_requests_total{namespace=\"$NS\",pod=~\"$SERVICE-$slot-.*\",status=~\"5..\"}[2m]))/sum(rate(http_requests_total{namespace=\"$NS\",pod=~\"$SERVICE-$slot-.*\"}[2m]))" \
    2>/dev/null | \
    python3 -c "import json,sys; d=json.load(sys.stdin); print(d['data']['result'][0]['value'][1] if d['data']['result'] else '0')" \
    2>/dev/null || echo "0")

  python3 -c "
rate = float('$rate')
threshold = float('$threshold')
if rate > threshold:
    print(f'ERROR_RATE_HIGH:{rate:.4f}')
    exit(1)
else:
    print(f'OK:{rate:.4f}')
    exit(0)
" && return 0 || return 1
}

# ── Promote: blue → green ─────────────────────────────────────
cmd_promote() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --namespace) NS="$2";   shift 2 ;;
      --image)     IMAGE="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local inactive; inactive=$(get_inactive_slot)
  local active;   active=$(get_active_slot)

  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║   BLUE/GREEN PROMOTION                        ║${NC}"
  echo -e "${BOLD}║   Active: $active → Target: $inactive     ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
  echo ""

  # ── Phase 1: Update image and scale up inactive slot ─────────
  info "Phase 1: Scaling up $inactive with new image..."
  if [ -n "$IMAGE" ]; then
    kubectl set image deployment/"$SERVICE-$inactive" \
      app="$IMAGE" -n "$NS"
    info "Updated $inactive image to: $IMAGE"
  fi

  kubectl scale deployment/"$SERVICE-$inactive" --replicas=5 -n "$NS"
  kubectl rollout status deployment/"$SERVICE-$inactive" -n "$NS" --timeout=5m
  pass "$inactive deployment ready"

  # ── Phase 2: Smoke test preview URL ──────────────────────────
  info "Phase 2: Smoke testing preview ($PREVIEW_URL)..."
  sleep 5   # Allow pods to stabilize

  local smoke_pass=true
  for endpoint in "/health" "/api/v1/status"; do
    if curl -sf --max-time 10 "$PREVIEW_URL$endpoint" > /dev/null 2>&1; then
      pass "Smoke test: $endpoint"
    else
      warn "Smoke test failed: $endpoint"
      smoke_pass=false
    fi
  done

  if ! $smoke_pass; then
    fail "Smoke tests failed on preview. NOT promoting. Scale down $inactive."
    kubectl scale deployment/"$SERVICE-$inactive" --replicas=0 -n "$NS"
    exit 1
  fi

  # ── Phase 3: Check error rate on preview slot ────────────────
  info "Phase 3: Checking error rate on $inactive slot (1 min)..."
  sleep 60
  if check_error_rate "$inactive" "0.05"; then
    pass "Error rate check passed on $inactive"
  else
    fail "Error rate too high on $inactive slot. NOT promoting."
    kubectl scale deployment/"$SERVICE-$inactive" --replicas=0 -n "$NS"
    exit 1
  fi

  # ── Phase 4: Atomic traffic switch ───────────────────────────
  info "Phase 4: Switching production traffic to $inactive..."
  local switch_time; switch_time=$(date -u '+%H:%M UTC')

  kubectl patch service "$SERVICE" -n "$NS" \
    -p "{\"spec\":{\"selector\":{\"app\":\"$SERVICE\",\"slot\":\"$inactive\"}}}"

  kubectl annotate service "$SERVICE" -n "$NS" \
    "deployment.company.com/active-slot=$inactive" \
    "deployment.company.com/switched-at=$switch_time" \
    --overwrite

  pass "Traffic switched to $inactive at $switch_time"
  info "Previous version ($active) still running — ready for instant rollback if needed"

  # ── Phase 5: Monitor post-switch ─────────────────────────────
  info "Phase 5: Monitoring error rate for $HEALTH_WINDOW seconds..."
  local failed=false
  for i in $(seq 1 $((HEALTH_WINDOW/30))); do
    sleep 30
    if check_error_rate "$inactive" "0.02"; then
      echo "  Check $i/$(($HEALTH_WINDOW/30)): OK"
    else
      warn "Error rate elevated after switch!"
      failed=true
      break
    fi
  done

  if $failed; then
    warn "Health check failed post-switch. Auto-rolling back to $active..."
    kubectl patch service "$SERVICE" -n "$NS" \
      -p "{\"spec\":{\"selector\":{\"app\":\"$SERVICE\",\"slot\":\"$active\"}}}"
    kubectl annotate service "$SERVICE" -n "$NS" \
      "deployment.company.com/active-slot=$active" \
      --overwrite
    fail "Rolled back to $active. Investigate $inactive before retrying."
  fi

  # ── Phase 6: Scale down old slot ─────────────────────────────
  info "Phase 6: Scaling down $active (was production)..."
  kubectl scale deployment/"$SERVICE-$active" --replicas=0 -n "$NS"
  pass "Scaled down $active"

  echo ""
  echo -e "${GREEN}${BOLD}══════════════════════════════════════════${NC}"
  echo -e "${GREEN}${BOLD}  PROMOTION COMPLETE: $active → $inactive  ${NC}"
  echo -e "${GREEN}${BOLD}  Image: ${IMAGE:-unchanged}              ${NC}"
  echo -e "${GREEN}${BOLD}══════════════════════════════════════════${NC}"
}

# ── Rollback: switch back to previous slot instantly ──────────
cmd_rollback() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --namespace) NS="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local active;   active=$(get_active_slot)
  local inactive; inactive=$(get_inactive_slot)

  warn "ROLLBACK: switching from $active → $inactive"

  # Scale up the inactive slot if it was scaled down
  INACTIVE_REPLICAS=$(kubectl get deployment/"$SERVICE-$inactive" -n "$NS" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  if [ "$INACTIVE_REPLICAS" = "0" ]; then
    info "Scaling up $inactive..."
    kubectl scale deployment/"$SERVICE-$inactive" --replicas=5 -n "$NS"
    kubectl rollout status deployment/"$SERVICE-$inactive" -n "$NS" --timeout=3m
  fi

  # Switch traffic back
  kubectl patch service "$SERVICE" -n "$NS" \
    -p "{\"spec\":{\"selector\":{\"app\":\"$SERVICE\",\"slot\":\"$inactive\"}}}"
  kubectl annotate service "$SERVICE" -n "$NS" \
    "deployment.company.com/active-slot=$inactive" \
    "deployment.company.com/rolled-back-at=$(date -u '+%H:%M UTC')" \
    --overwrite

  pass "Rollback complete. Traffic now on: $inactive"
  info "Post-rollback: verify error rate is back to baseline"
}

case "$COMMAND" in
  promote)  cmd_promote "$@" ;;
  rollback) cmd_rollback "$@" ;;
  status)
    echo "Active slot: $(get_active_slot)"
    echo "Inactive slot: $(get_inactive_slot)"
    kubectl get pods -n "$NS" -l "app=$SERVICE" -o wide
    ;;
  *)
    echo "Blue/Green Traffic Switch"
    echo ""
    echo "Commands:"
    echo "  promote  --namespace <ns> --image <img>  Promote green to production"
    echo "  rollback --namespace <ns>                 Instant rollback to previous"
    echo "  status                                    Show current active slot"
    ;;
esac
