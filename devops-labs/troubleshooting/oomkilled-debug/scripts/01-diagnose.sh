#!/bin/bash
# =============================================================
# Script 01 — OOMKilled Full Diagnosis
# Usage:  bash 01-diagnose.sh <pod-name> <namespace>
# =============================================================

set -euo pipefail

POD="${1:-}"
NS="${2:-production}"
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
section() { echo -e "\n${BOLD}${CYAN}═══ $* ═══${NC}"; }

if [ -z "$POD" ]; then
  echo "Usage: $0 <pod-name> [namespace]"
  echo ""
  echo "Or find OOMKilled pods automatically:"
  echo "  kubectl get pods -A -o json | \\"
  echo "    jq -r '.items[] | select(.status.containerStatuses[]?.lastState.terminated.reason==\"OOMKilled\") | \"\(.metadata.namespace)/\(.metadata.name)\"'"
  exit 1
fi

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     OOMKilled Diagnosis Report           ║${NC}"
echo -e "${BOLD}║     Pod: $POD${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"

# ── STEP 1: Confirm OOMKill ───────────────────────────────────
section "STEP 1: Confirm OOMKill"

DESCRIBE=$(kubectl describe pod "$POD" -n "$NS" 2>/dev/null)
if [ -z "$DESCRIBE" ]; then
  error "Pod '$POD' not found in namespace '$NS'"
  exit 1
fi

# Extract exit code and reason from last state
EXIT_CODE=$(kubectl get pod "$POD" -n "$NS" -o jsonpath=\
'{.status.containerStatuses[0].lastState.terminated.exitCode}' 2>/dev/null || echo "")
REASON=$(kubectl get pod "$POD" -n "$NS" -o jsonpath=\
'{.status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null || echo "")

if [ "$EXIT_CODE" = "137" ] || [ "$REASON" = "OOMKilled" ]; then
  error "CONFIRMED: OOMKilled (exit code $EXIT_CODE)"
else
  warn "Exit code: ${EXIT_CODE:-unknown} | Reason: ${REASON:-unknown}"
  warn "May not be OOMKill. Continuing analysis anyway..."
fi

# Memory limit
MEM_LIMIT=$(kubectl get pod "$POD" -n "$NS" -o jsonpath=\
'{.spec.containers[0].resources.limits.memory}' 2>/dev/null || echo "NOT SET")
MEM_REQ=$(kubectl get pod "$POD" -n "$NS" -o jsonpath=\
'{.spec.containers[0].resources.requests.memory}' 2>/dev/null || echo "NOT SET")

echo ""
echo "  Memory Limit:   ${MEM_LIMIT}"
echo "  Memory Request: ${MEM_REQ}"

if [ "$MEM_LIMIT" = "NOT SET" ]; then
  error "No memory limit set! Pod can use unlimited memory — dangerous in production."
fi

# Restart count
RESTARTS=$(kubectl get pod "$POD" -n "$NS" -o jsonpath=\
'{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
echo "  Restart Count:  ${RESTARTS}"

if [ "$RESTARTS" -gt 5 ]; then
  warn "High restart count ($RESTARTS) — recurring OOMKill detected"
fi

# ── STEP 2: Current Resource Usage ───────────────────────────
section "STEP 2: Current Memory Usage"

if kubectl top pod "$POD" -n "$NS" --no-headers 2>/dev/null; then
  info "^ Current usage. Compare vs limit: $MEM_LIMIT"
else
  warn "metrics-server not available. Install with:"
  echo "  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
fi

# ── STEP 3: Container-level resource breakdown ────────────────
section "STEP 3: All Containers Resource Config"

kubectl get pod "$POD" -n "$NS" \
  -o jsonpath='{range .spec.containers[*]}Container: {.name}{"\n"}  CPU:    req={.resources.requests.cpu}  lim={.resources.limits.cpu}{"\n"}  Memory: req={.resources.requests.memory}  lim={.resources.limits.memory}{"\n\n"}{end}' \
  2>/dev/null || warn "Could not get resource info"

# ── STEP 4: Events ────────────────────────────────────────────
section "STEP 4: Pod Events (last 20)"

kubectl get events -n "$NS" \
  --field-selector "involvedObject.name=$POD" \
  --sort-by='.lastTimestamp' 2>/dev/null | tail -20 || \
  warn "No events found for this pod"

# ── STEP 5: Logs before crash ─────────────────────────────────
section "STEP 5: Logs Before Last Crash (--previous)"

echo "Looking for memory-related errors in previous container logs..."
kubectl logs "$POD" -n "$NS" --previous 2>/dev/null | \
  grep -iE "memory|oom|malloc|heap|killed|gc|allocation" | \
  tail -30 || \
  warn "No previous logs available (container has been recycled too many times)"

# ── STEP 6: Node pressure ─────────────────────────────────────
section "STEP 6: Node Memory Pressure"

NODE=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")
if [ -n "$NODE" ]; then
  echo "Pod is scheduled on node: $NODE"
  echo ""
  kubectl describe node "$NODE" 2>/dev/null | grep -A5 "Conditions:" | \
    grep -E "MemoryPressure|Ready|DiskPressure" || true
  echo ""
  echo "Node allocatable vs allocated:"
  kubectl describe node "$NODE" 2>/dev/null | grep -A8 "Allocated resources:" || true
else
  warn "Pod not currently running on a node"
fi

# ── STEP 7: Summary and recommendations ──────────────────────
section "STEP 7: Diagnosis Summary"

echo ""
echo "  Pod:            $POD"
echo "  Namespace:      $NS"
echo "  Restart Count:  $RESTARTS"
echo "  Memory Limit:   $MEM_LIMIT"
echo "  Memory Request: $MEM_REQ"
echo "  OOM Confirmed:  $([ "$EXIT_CODE" = "137" ] && echo 'YES' || echo 'CHECK LOGS')"
echo ""

echo "Recommended next steps:"
echo "  1. Run: bash 02-memory-profile.sh $POD $NS"
echo "     → Generates memory trend graph via Prometheus"
echo ""
echo "  2. Temporary fix (stop restarts):"
echo "     kubectl set resources deployment/<deploy-name> -n $NS \\"
echo "       --containers=<container-name> --limits=memory=512Mi"
echo ""
echo "  3. Long-term right-sizing:"
echo "     bash 03-goldilocks-setup.sh"
echo "     → Installs VPA + Goldilocks for visual recommendations"
echo ""
echo "  4. Add OOM alert (fires at 80% of limit):"
echo "     kubectl apply -f ../prometheus/oom-alert-rules.yaml"
