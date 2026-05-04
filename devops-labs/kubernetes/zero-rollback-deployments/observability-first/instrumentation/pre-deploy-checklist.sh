#!/bin/bash
# =============================================================
# Pre-Deploy Observability Checklist
# Verifies the new version has all required instrumentation
# BEFORE it gets promoted to production.
#
# Usage: bash pre-deploy-checklist.sh --url https://staging.company.com
# Exits 0 (pass) or 1 (fail — block the deploy)
# =============================================================

set -euo pipefail

BASE_URL="${1:-}"
while [[ $# -gt 0 ]]; do
  case $1 in
    --url) BASE_URL="$2"; shift 2 ;;
    *) shift ;;
  esac
done

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

check_pass() { echo -e "  ${GREEN}✅${NC} $*"; PASS_COUNT=$((PASS_COUNT+1)); }
check_fail() { echo -e "  ${RED}❌${NC} $*"; FAIL_COUNT=$((FAIL_COUNT+1)); }
check_warn() { echo -e "  ${YELLOW}⚠️${NC}  $*"; WARN_COUNT=$((WARN_COUNT+1)); }

echo ""
echo -e "${BOLD}╔═══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Pre-Deploy Observability Checklist              ║${NC}"
echo -e "${BOLD}║   Target: $BASE_URL${NC}"
echo -e "${BOLD}╚═══════════════════════════════════════════════════╝${NC}"

# ── 1. Health endpoints ───────────────────────────────────────
echo ""
echo -e "${BOLD}--- 1. Health Endpoints ---${NC}"

for path in "/health" "/health/live" "/health/ready" "/health/started" "/healthz"; do
  HTTP_CODE=$(curl -sf --max-time 5 -o /dev/null -w "%{http_code}" \
    "${BASE_URL}${path}" 2>/dev/null || echo "000")
  if [ "$HTTP_CODE" = "200" ]; then
    check_pass "$path returns 200"
  elif [ "$HTTP_CODE" = "000" ]; then
    check_warn "$path not accessible (may not be required)"
  else
    check_fail "$path returned $HTTP_CODE (expected 200)"
  fi
done

# ── 2. Metrics endpoint ───────────────────────────────────────
echo ""
echo -e "${BOLD}--- 2. Prometheus Metrics Endpoint ---${NC}"

METRICS=$(curl -sf --max-time 10 "${BASE_URL}/metrics" 2>/dev/null || echo "")
if [ -z "$METRICS" ]; then
  check_fail "/metrics endpoint not responding"
else
  check_pass "/metrics endpoint responding"

  # Check for required metrics
  REQUIRED_METRICS=(
    "http_requests_total"
    "http_request_duration_seconds"
    "http_requests_in_progress"
    "app_info"
    "app_deploy_timestamp_seconds"
  )

  for metric in "${REQUIRED_METRICS[@]}"; do
    if echo "$METRICS" | grep -q "^# HELP $metric"; then
      check_pass "Metric exists: $metric"
    else
      check_fail "MISSING metric: $metric"
    fi
  done

  # Check http_request_duration has correct bucket range
  if echo "$METRICS" | grep -q 'http_request_duration_seconds_bucket{.*le="0.5"'; then
    check_pass "Latency histogram has 500ms bucket (needed for SLO)"
  else
    check_warn "No 500ms bucket in latency histogram — SLO alerts may be inaccurate"
  fi

  # Check version label present
  if echo "$METRICS" | grep -q 'app_info{.*version='; then
    VERSION=$(echo "$METRICS" | grep 'app_info{' | grep -o 'version="[^"]*"' | head -1)
    check_pass "App version instrumented: $VERSION"
  else
    check_fail "app_info metric missing version label"
  fi

  # Check metric cardinality isn't exploding
  UNIQUE_ENDPOINTS=$(echo "$METRICS" | grep 'http_requests_total{' | \
    grep -o 'endpoint="[^"]*"' | sort -u | wc -l | tr -d ' ')
  if [ "$UNIQUE_ENDPOINTS" -lt 100 ]; then
    check_pass "Endpoint cardinality OK: $UNIQUE_ENDPOINTS unique endpoints"
  else
    check_fail "HIGH CARDINALITY: $UNIQUE_ENDPOINTS unique endpoints in metrics (should be < 100)"
  fi
fi

# ── 3. Log format check ───────────────────────────────────────
echo ""
echo -e "${BOLD}--- 3. Log Format ---${NC}"

# Check that app logs are JSON structured (for Loki)
LOGS=$(curl -sf --max-time 5 "${BASE_URL}/health" 2>/dev/null || echo "")
if kubectl logs -l "app=$(basename $BASE_URL)" --tail=5 2>/dev/null | \
    python3 -c "import sys,json; [json.loads(l) for l in sys.stdin if l.strip()]" 2>/dev/null; then
  check_pass "Logs are JSON structured (Loki compatible)"
else
  check_warn "Could not verify log format — ensure logs are JSON structured"
fi

# ── 4. Tracing headers check ─────────────────────────────────
echo ""
echo -e "${BOLD}--- 4. Distributed Tracing ---${NC}"

TRACE_HEADERS=$(curl -sI --max-time 5 \
  -H "x-b3-traceid: abc123" \
  -H "x-b3-spanid: def456" \
  "${BASE_URL}/health" 2>/dev/null || echo "")

if echo "$TRACE_HEADERS" | grep -qi "x-trace-id\|traceparent\|x-request-id"; then
  check_pass "Service propagates trace context in response headers"
else
  check_warn "No trace headers in response — verify OpenTelemetry is configured"
fi

# ── 5. Error simulation ───────────────────────────────────────
echo ""
echo -e "${BOLD}--- 5. Error Observability Smoke Test ---${NC}"

# Hit a non-existent endpoint and verify it appears in metrics
HTTP_404=$(curl -sf --max-time 5 -o /dev/null -w "%{http_code}" \
  "${BASE_URL}/this-does-not-exist-12345" 2>/dev/null || echo "000")

if [ "$HTTP_404" = "404" ]; then
  # Wait a moment for metrics to update
  sleep 3
  FOUR_OH_FOUR=$(curl -sf --max-time 5 "${BASE_URL}/metrics" 2>/dev/null | \
    grep 'http_requests_total.*status_code="404"' | head -1 || echo "")
  if [ -n "$FOUR_OH_FOUR" ]; then
    check_pass "404 errors appear in http_requests_total metric"
  else
    check_warn "404 request not visible in metrics (may be rate-limited or counter not updated)"
  fi
fi

# ── 6. Summary ───────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔═══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   CHECKLIST RESULTS                               ║${NC}"
echo -e "${BOLD}╚═══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${GREEN}Passed: $PASS_COUNT${NC}"
echo -e "  ${YELLOW}Warnings: $WARN_COUNT${NC}"
echo -e "  ${RED}Failed: $FAIL_COUNT${NC}"
echo ""

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo -e "${RED}${BOLD}❌ DEPLOY BLOCKED: $FAIL_COUNT required checks failed${NC}"
  echo ""
  echo "  Fix the failing checks before deploying."
  echo "  Unobservable deployments create incidents you cannot diagnose."
  exit 1
elif [ "$WARN_COUNT" -gt 0 ]; then
  echo -e "${YELLOW}${BOLD}⚠️  DEPLOY ALLOWED WITH WARNINGS: $WARN_COUNT items to address${NC}"
  echo ""
  echo "  Deploy may proceed but address warnings before next release."
  exit 0
else
  echo -e "${GREEN}${BOLD}✅ ALL CHECKS PASSED — DEPLOY APPROVED${NC}"
  echo ""
  echo "  This version has full observability coverage."
  exit 0
fi
