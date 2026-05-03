#!/bin/bash
# =============================================================
# Script 03 — Goldilocks (Fairwinds) + VPA Setup
# Provides a web UI showing current vs recommended resource settings
# Usage:  bash 03-goldilocks-setup.sh [namespace-to-enable]
# =============================================================

set -euo pipefail

ENABLE_NS="${1:-production}"

echo "=== Goldilocks + VPA Setup ==="
echo ""
echo "Goldilocks runs VPA in recommendation mode for all deployments"
echo "and provides a UI showing under/over-provisioned containers."
echo ""

# ── Step 1: Install VPA ───────────────────────────────────────
echo "--- Step 1: Installing Vertical Pod Autoscaler (VPA) ---"
echo ""

# Check if VPA already installed
if kubectl get crd verticalpodautoscalers.autoscaling.k8s.io &>/dev/null; then
  echo "VPA already installed"
else
  echo "Installing VPA..."

  # Clone VPA repo and install
  TMPDIR=$(mktemp -d)
  git clone --depth=1 \
    https://github.com/kubernetes/autoscaler.git "$TMPDIR/autoscaler" \
    2>/dev/null

  cd "$TMPDIR/autoscaler/vertical-pod-autoscaler"
  ./hack/vpa-install.sh

  echo "VPA installed!"
  rm -rf "$TMPDIR"
fi

# Verify VPA components
echo ""
echo "VPA components:"
kubectl get pods -n kube-system | grep -E "vpa-|recommender|updater|admission" || \
  echo "VPA pods starting..."

# ── Step 2: Install Goldilocks via Helm ───────────────────────
echo ""
echo "--- Step 2: Installing Goldilocks ---"
echo ""

helm repo add fairwinds-stable https://charts.fairwinds.com/stable 2>/dev/null || true
helm repo update

if helm list -n goldilocks 2>/dev/null | grep -q goldilocks; then
  echo "Goldilocks already installed"
else
  kubectl create namespace goldilocks 2>/dev/null || true

  helm install goldilocks fairwinds-stable/goldilocks \
    --namespace goldilocks \
    --set dashboard.enabled=true \
    --set dashboard.replicaCount=1 \
    --wait \
    --timeout 5m

  echo "Goldilocks installed!"
fi

# ── Step 3: Enable Goldilocks for a namespace ─────────────────
echo ""
echo "--- Step 3: Enabling Goldilocks for namespace: $ENABLE_NS ---"
echo ""

# This label tells Goldilocks to create VPA objects for all
# Deployments in the labelled namespace
kubectl label namespace "$ENABLE_NS" \
  goldilocks.fairwinds.com/enabled=true \
  --overwrite

echo "Goldilocks enabled for namespace: $ENABLE_NS"
echo ""
echo "Goldilocks will now create VPA objects (in recommendation mode)"
echo "for every Deployment in $ENABLE_NS"
echo ""

# Show VPA objects being created
echo "Waiting 30s for VPA recommendations to populate..."
sleep 30
kubectl get vpa -n "$ENABLE_NS" 2>/dev/null || echo "VPA objects still populating..."

# ── Step 4: Access the dashboard ─────────────────────────────
echo ""
echo "--- Step 4: Access Goldilocks Dashboard ---"
echo ""
echo "Run this to open the dashboard:"
echo ""
echo "  kubectl port-forward svc/goldilocks-dashboard 8080:80 -n goldilocks &"
echo "  open http://localhost:8080"
echo ""
echo "The dashboard shows:"
echo "  - Every deployment and container"
echo "  - Current CPU/memory requests and limits"
echo "  - Recommended values (Burstable and Guaranteed QoS)"
echo "  - Color-coded: green=ok, red=needs change"
echo ""

# ── Step 5: CLI recommendations (no UI needed) ───────────────
echo "--- Step 5: Get Recommendations via CLI ---"
echo ""
echo "Get VPA recommendations for all deployments in $ENABLE_NS:"
echo ""

kubectl get vpa -n "$ENABLE_NS" -o json 2>/dev/null | python3 - << 'PYEOF'
import json, sys

data = json.load(sys.stdin)
items = data.get("items", [])

if not items:
    print("  No VPA objects yet. Wait a few minutes and retry.")
    sys.exit(0)

print(f"{'DEPLOYMENT':<30} {'CONTAINER':<20} {'CPU-REQ':<10} {'MEM-REQ':<10} {'CPU-LIM':<10} {'MEM-LIM':<10}")
print("-" * 90)

for vpa in items:
    name = vpa["metadata"]["name"]
    recs = vpa.get("status", {}).get("recommendation", {})
    containers = recs.get("containerRecommendations", [])

    for c in containers:
        cname = c.get("containerName", "?")
        lower = c.get("lowerBound", {})
        upper = c.get("upperBound", {})
        target = c.get("target", {})

        cpu_req  = target.get("cpu",    "?")
        mem_req  = target.get("memory", "?")
        cpu_lim  = upper.get("cpu",    "?")
        mem_lim  = upper.get("memory", "?")

        print(f"  {name:<28} {cname:<20} {cpu_req:<10} {mem_req:<10} {cpu_lim:<10} {mem_lim:<10}")
PYEOF

echo ""
echo "To apply recommendations, run:"
echo "  bash 04-rightsize.sh <deployment-name> $ENABLE_NS"
