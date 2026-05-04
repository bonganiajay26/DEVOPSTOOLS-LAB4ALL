#!/bin/bash
# =============================================================
# ArgoCD Post-Sync Hook — Runs after every sync
# If metrics degrade: creates a sync failure → ArgoCD marks
# the application degraded and can auto-rollback.
#
# Used as: argocd.argoproj.io/hook: PostSync
# in a Job manifest inside your GitOps repo.
# =============================================================

set -euo pipefail

NS="${ARGOCD_APP_NAMESPACE:-production}"
APP="${ARGOCD_APP_NAME:-myapp}"
PROM="${PROMETHEUS_URL:-http://prometheus-operated.monitoring:9090}"

echo "=== Post-Sync Health Check: $APP ($NS) ==="
echo "Time: $(date -u '+%H:%M UTC')"
echo ""

# Wait for pods to become ready first
echo "Waiting for rollout to complete..."
kubectl rollout status deployment/"$APP" -n "$NS" --timeout=3m || {
  echo "FAIL: Deployment rollout did not complete within 3 minutes"
  exit 1
}
echo "Rollout complete. Waiting 60s for traffic to warm up..."
sleep 60

# ── Check 1: Error rate (2-min window) ───────────────────────
ERROR_RATE=$(curl -sf "$PROM/api/v1/query" \
  --data-urlencode "query=sum(rate(http_requests_total{namespace=\"$NS\",status=~\"5..\"}[2m]))/sum(rate(http_requests_total{namespace=\"$NS\"}[2m]))" \
  2>/dev/null | \
  python3 -c "import json,sys; d=json.load(sys.stdin); r=d['data']['result']; print(r[0]['value'][1] if r else '0')" || echo "0")

python3 << PYEOF
rate = float("$ERROR_RATE" or "0")
if rate > 0.05:
    print(f"FAIL: Error rate {rate:.3f} ({rate*100:.1f}%) exceeds 5% threshold post-sync")
    exit(1)
elif rate > 0.01:
    print(f"WARN: Error rate {rate:.3f} ({rate*100:.1f}%) is elevated — watch closely")
else:
    print(f"PASS: Error rate {rate:.4f} ({rate*100:.2f}%) — within threshold")
PYEOF

echo ""

# ── Check 2: Pod readiness ─────────────────────────────────────
READY=$(kubectl get deployment "$APP" -n "$NS" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
DESIRED=$(kubectl get deployment "$APP" -n "$NS" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")

if [ "$READY" != "$DESIRED" ]; then
  echo "FAIL: Only $READY/$DESIRED pods ready after sync"
  exit 1
fi
echo "PASS: All $READY/$DESIRED pods ready"

# ── Check 3: No new crash loops ───────────────────────────────
CRASHES=$(kubectl get pods -n "$NS" -l "app=$APP" --no-headers 2>/dev/null | \
  grep -c "CrashLoopBackOff\|Error\|OOMKilled" || echo "0")

if [ "$CRASHES" -gt 0 ]; then
  echo "FAIL: $CRASHES pods in crash state post-sync"
  kubectl get pods -n "$NS" -l "app=$APP" | grep -v Running || true
  exit 1
fi
echo "PASS: No pods in crash state"

echo ""
echo "=== Post-sync health checks PASSED ==="
echo "ArgoCD will mark application Healthy."
