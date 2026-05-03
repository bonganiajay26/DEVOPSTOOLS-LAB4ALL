#!/bin/bash
# =============================================================
# Script 04 — Apply Right-Sized Resources from VPA Recommendations
# Reads VPA recommendation → adds 20% headroom → applies to Deployment
# Usage:  bash 04-rightsize.sh <deployment-name> <namespace>
# =============================================================

set -euo pipefail

DEPLOY="${1:-}"
NS="${2:-production}"
HEADROOM="${3:-20}"          # % headroom added above p99 recommendation

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
BOLD='\033[1m'; NC='\033[0m'

if [ -z "$DEPLOY" ]; then
  echo "Usage: $0 <deployment-name> [namespace] [headroom-%]"
  echo ""
  echo "Available deployments with VPA recommendations:"
  kubectl get vpa -n "${NS:-production}" --no-headers 2>/dev/null | \
    awk '{print "  "$1}' || echo "  No VPA objects found"
  exit 1
fi

echo ""
echo -e "${BOLD}=== Resource Right-Sizing: $DEPLOY ($NS) ===${NC}"
echo "    Headroom: +${HEADROOM}% above VPA recommendation"
echo ""

# ── Get VPA recommendation ────────────────────────────────────
VPA_JSON=$(kubectl get vpa "$DEPLOY" -n "$NS" -o json 2>/dev/null || echo "{}")
CONTAINERS=$(echo "$VPA_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
recs = data.get('status', {}).get('recommendation', {})
containers = recs.get('containerRecommendations', [])
if not containers:
    print('NO_DATA')
else:
    for c in containers:
        name    = c.get('containerName', 'unknown')
        target  = c.get('target', {})
        upper   = c.get('upperBound', {})
        cpu_req = target.get('cpu', '100m')
        mem_rec = target.get('memory', '128Mi')
        cpu_lim = upper.get('cpu', '500m')
        mem_lim = upper.get('memory', '256Mi')
        print(f'{name}|{cpu_req}|{mem_rec}|{cpu_lim}|{mem_lim}')
" 2>/dev/null)

if [ "$CONTAINERS" = "NO_DATA" ] || [ -z "$CONTAINERS" ]; then
  echo -e "${YELLOW}No VPA recommendation found for $DEPLOY.${NC}"
  echo ""
  echo "Either:"
  echo "  1. VPA not installed → run bash 03-goldilocks-setup.sh"
  echo "  2. Not enough data yet → wait 30 minutes with traffic running"
  echo "  3. No VPA object for this deployment → run:"
  echo "     kubectl apply -f ../manifests/vpa-recommendation.yaml"
  echo ""
  echo "Falling back to current usage + ${HEADROOM}% headroom..."
  echo ""

  # Fallback: use current top metrics
  CURRENT=$(kubectl top pod -l "app=$DEPLOY" -n "$NS" --no-headers 2>/dev/null | head -1 || echo "")
  if [ -n "$CURRENT" ]; then
    echo "Current usage: $CURRENT"
    echo "Manually calculate: current + ${HEADROOM}% headroom"
  fi
  exit 1
fi

# ── Apply with headroom ───────────────────────────────────────
echo "VPA Recommendations:"
echo ""
echo "$CONTAINERS" | while IFS="|" read -r CNAME CPU_REQ MEM_REC CPU_LIM MEM_LIM; do
  echo "  Container: $CNAME"
  echo "    VPA recommends:  cpu_req=$CPU_REQ  mem_limit=$MEM_LIM"

  # Add headroom: parse Mi/Gi, add percentage
  NEW_MEM_LIMIT=$(python3 << PYEOF
import re

def parse_mem(s):
    """Convert Ki/Mi/Gi to bytes"""
    m = re.match(r'(\d+)([KMGkmg]i?)?', s.strip())
    if not m: return 256 * 1024 * 1024
    val = int(m.group(1))
    unit = (m.group(2) or '').upper().rstrip('I')
    return val * {'K':1024,'M':1024**2,'G':1024**3}.get(unit, 1)

def fmt_mem(b):
    """Format bytes to nearest Mi"""
    return f"{round(b / (1024**2))}Mi"

recommended = parse_mem("$MEM_LIM")
with_headroom = recommended * (1 + $HEADROOM / 100)
print(fmt_mem(with_headroom))
PYEOF
  )

  echo "    With +${HEADROOM}% headroom: mem_limit=$NEW_MEM_LIMIT"
  echo ""

  # Confirm before applying
  read -p "  Apply $NEW_MEM_LIMIT memory limit to container '$CNAME'? [y/N] " confirm
  if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then

    # Patch the deployment
    kubectl set resources deployment/"$DEPLOY" \
      -n "$NS" \
      --containers="$CNAME" \
      --limits="cpu=$CPU_LIM,memory=$NEW_MEM_LIMIT" \
      --requests="cpu=$CPU_REQ,memory=$MEM_REC"

    echo -e "    ${GREEN}Applied! Watching rollout...${NC}"
    kubectl rollout status deployment/"$DEPLOY" -n "$NS" --timeout=3m

    # Verify new limits
    NEW_LIMIT=$(kubectl get deployment "$DEPLOY" -n "$NS" \
      -o jsonpath="{.spec.template.spec.containers[?(@.name==\"$CNAME\")].resources.limits.memory}")
    echo -e "    ${GREEN}New memory limit: $NEW_LIMIT${NC}"
  else
    echo "    Skipped."
  fi
done

echo ""
echo "=== Right-Sizing Complete ==="
echo ""
echo "Next: Add an early-warning alert (fires at 80% of new limit):"
echo "  kubectl apply -f ../prometheus/oom-alert-rules.yaml"
echo ""
echo "Monitor with:"
echo "  watch kubectl top pod -l app=$DEPLOY -n $NS"
