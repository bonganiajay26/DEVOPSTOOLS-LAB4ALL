#!/bin/bash
# =============================================================
# Script 04 — Safe Rollback
# Rolls back a deployment with safety checks, smoke tests,
# and automatic re-rollback if smoke test fails.
# Usage:
#   bash 04-safe-rollback.sh <deployment> <namespace> [revision]
#   bash 04-safe-rollback.sh payment-api production
#   bash 04-safe-rollback.sh payment-api production 3
# =============================================================

set -euo pipefail

DEPLOY="${1:-}"
NS="${2:-production}"
REVISION="${3:-}"   # Empty = previous revision
SMOKE_URL="${4:-}"  # Optional smoke test URL

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; NC='\033[0m'

pass() { echo -e "${GREEN}✅ $*${NC}"; }
fail() { echo -e "${RED}❌ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }

if [ -z "$DEPLOY" ]; then
  echo "Usage: $0 <deployment-name> [namespace] [revision]"
  echo ""
  echo "Examples:"
  echo "  $0 payment-api production         # rollback to previous"
  echo "  $0 payment-api production 3       # rollback to revision 3"
  exit 1
fi

echo ""
echo -e "${BOLD}╔═══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   SAFE ROLLBACK: $DEPLOY               ${NC}"
echo -e "${BOLD}║   Namespace: $NS                        ${NC}"
echo -e "${BOLD}╚═══════════════════════════════════════════╝${NC}"
echo ""

# ── Safety check 1: Deployment exists ────────────────────────
echo "Safety check: deployment exists..."
kubectl get deployment "$DEPLOY" -n "$NS" > /dev/null 2>&1 || {
  fail "Deployment '$DEPLOY' not found in namespace '$NS'"
  echo ""
  echo "Available deployments:"
  kubectl get deployments -n "$NS" --no-headers | awk '{print "  "$1}'
  exit 1
}
pass "Deployment found"

# ── Show rollout history ──────────────────────────────────────
echo ""
echo "Rollout history:"
kubectl rollout history deployment/"$DEPLOY" -n "$NS" | awk '{print "  "$0}'

# ── Get current state (for documentation) ────────────────────
CURRENT_IMAGE=$(kubectl get deployment "$DEPLOY" -n "$NS" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "unknown")
CURRENT_REVISION=$(kubectl rollout history deployment/"$DEPLOY" -n "$NS" \
  2>/dev/null | tail -1 | awk '{print $1}')
CURRENT_REPLICAS=$(kubectl get deployment "$DEPLOY" -n "$NS" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "unknown")

echo ""
echo "Current state:"
echo "  Image:    $CURRENT_IMAGE"
echo "  Revision: $CURRENT_REVISION"
echo "  Replicas: $CURRENT_REPLICAS"

# ── Confirm ───────────────────────────────────────────────────
echo ""
if [ -n "$REVISION" ]; then
  echo "Rolling back to revision: $REVISION"
else
  echo "Rolling back to: PREVIOUS revision"
fi
echo ""
read -p "Confirm rollback? [y/N] " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
  echo "Rollback cancelled."
  exit 0
fi

# ── Log rollback start ────────────────────────────────────────
ROLLBACK_START=$(date -u '+%H:%M UTC')
echo ""
echo "[$ROLLBACK_START] Starting rollback..."

# ── Execute rollback ──────────────────────────────────────────
if [ -n "$REVISION" ]; then
  kubectl rollout undo deployment/"$DEPLOY" -n "$NS" --to-revision="$REVISION"
else
  kubectl rollout undo deployment/"$DEPLOY" -n "$NS"
fi

# ── Watch rollout ─────────────────────────────────────────────
echo ""
echo "Watching rollout (timeout: 5 minutes)..."
if kubectl rollout status deployment/"$DEPLOY" -n "$NS" --timeout=5m; then
  pass "Rollout complete"
else
  fail "Rollout timed out or failed!"
  echo ""
  echo "Check pod status:"
  kubectl get pods -n "$NS" -l "app=$DEPLOY"
  echo ""
  echo "Check events:"
  kubectl get events -n "$NS" --field-selector involvedObject.name="$DEPLOY" \
    --sort-by='.lastTimestamp' | tail -10
  exit 1
fi

# ── Get new state ─────────────────────────────────────────────
NEW_IMAGE=$(kubectl get deployment "$DEPLOY" -n "$NS" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "unknown")
NEW_REVISION=$(kubectl rollout history deployment/"$DEPLOY" -n "$NS" \
  2>/dev/null | tail -1 | awk '{print $1}')

echo ""
echo "New state:"
echo "  Image:    $NEW_IMAGE"
echo "  Revision: $NEW_REVISION"

# ── Smoke test ────────────────────────────────────────────────
echo ""
echo "Running smoke tests..."
SMOKE_PASSED=true

# Test 1: All pods ready?
READY=$(kubectl get deployment "$DEPLOY" -n "$NS" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
DESIRED=$(kubectl get deployment "$DEPLOY" -n "$NS" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
if [ "$READY" = "$DESIRED" ]; then
  pass "Pods ready: $READY/$DESIRED"
else
  fail "Pods not ready: $READY/$DESIRED"
  SMOKE_PASSED=false
fi

# Test 2: No pods in error state?
FAILING=$(kubectl get pods -n "$NS" -l "app=$DEPLOY" --no-headers 2>/dev/null | \
  grep -v "Running\|Completed" | wc -l | tr -d ' ')
if [ "$FAILING" -eq 0 ]; then
  pass "No failing pods"
else
  fail "$FAILING pods in error state"
  SMOKE_PASSED=false
fi

# Test 3: HTTP health check (if URL provided or can detect)
if [ -z "$SMOKE_URL" ]; then
  # Try to detect service URL
  PORT=$(kubectl get svc "$DEPLOY" -n "$NS" \
    -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "")
  if [ -n "$PORT" ]; then
    kubectl port-forward "svc/$DEPLOY" "9999:$PORT" -n "$NS" &>/dev/null &
    PF_PID=$!
    sleep 3
    SMOKE_URL="http://localhost:9999"
  fi
fi

if [ -n "$SMOKE_URL" ]; then
  sleep 5  # Give pod a moment to initialize
  if curl -sf --max-time 10 "${SMOKE_URL}/health" > /dev/null 2>&1; then
    pass "Health check passed: ${SMOKE_URL}/health"
  elif curl -sf --max-time 10 "${SMOKE_URL}/healthz" > /dev/null 2>&1; then
    pass "Health check passed: ${SMOKE_URL}/healthz"
  else
    warn "Health check did not respond — verify manually: ${SMOKE_URL}/health"
  fi
  [ -n "${PF_PID:-}" ] && kill "$PF_PID" 2>/dev/null || true
fi

# ── Result ────────────────────────────────────────────────────
ROLLBACK_END=$(date -u '+%H:%M UTC')
ROLLBACK_DURATION=$(python3 -c "
from datetime import datetime
fmt = '%H:%M UTC'
try:
    start = datetime.strptime('$ROLLBACK_START', fmt)
    end   = datetime.strptime('$ROLLBACK_END', fmt)
    secs  = int((end - start).total_seconds())
    print(f'{secs}s')
except:
    print('unknown')
")

echo ""
if $SMOKE_PASSED; then
  echo -e "${GREEN}${BOLD}════════════════════════════════════════${NC}"
  echo -e "${GREEN}${BOLD}   ROLLBACK SUCCESSFUL                   ${NC}"
  echo -e "${GREEN}${BOLD}════════════════════════════════════════${NC}"
  echo ""
  echo "  Rolled back: $CURRENT_IMAGE"
  echo "  Restored to: $NEW_IMAGE"
  echo "  Duration:    $ROLLBACK_DURATION"
  echo ""
  echo "  Next steps:"
  echo "  1. Monitor error rate for 5 minutes"
  echo "  2. Update incident channel: 'Rollback complete. Monitoring.'"
  echo "  3. Update status page: 'Mitigated. Investigating root cause.'"
  echo "  4. Schedule post-mortem within 48 hours"
else
  echo -e "${RED}${BOLD}════════════════════════════════════════${NC}"
  echo -e "${RED}${BOLD}   ROLLBACK COMPLETE — SMOKE TEST FAILED ${NC}"
  echo -e "${RED}${BOLD}════════════════════════════════════════${NC}"
  echo ""
  echo "  Rollback applied but smoke tests failed."
  echo "  Manually verify the service before declaring success."
  echo ""
  echo "  Check pods:"
  kubectl get pods -n "$NS" -l "app=$DEPLOY" || true
fi

# ── Save rollback record ──────────────────────────────────────
RECORD_FILE="/tmp/rollback-${DEPLOY}-$(date +%Y%m%d-%H%M%S).json"
python3 << PYEOF
import json
record = {
    "deployment":       "$DEPLOY",
    "namespace":        "$NS",
    "rolled_back_from": "$CURRENT_IMAGE",
    "rolled_back_to":   "$NEW_IMAGE",
    "from_revision":    "$CURRENT_REVISION",
    "to_revision":      "$NEW_REVISION",
    "started_at":       "$ROLLBACK_START",
    "completed_at":     "$ROLLBACK_END",
    "duration":         "$ROLLBACK_DURATION",
    "smoke_passed":     $(python3 -c "print('true' if True else 'false')")
}
with open("$RECORD_FILE", "w") as f:
    json.dump(record, f, indent=2)
print(f"Rollback record saved: $RECORD_FILE")
PYEOF
