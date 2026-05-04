#!/bin/bash
# Install Argo Rollouts + kubectl plugin

set -euo pipefail
echo "=== Installing Argo Rollouts ==="

# Install controller
kubectl create namespace argo-rollouts 2>/dev/null || true
kubectl apply -n argo-rollouts \
  -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

# Install kubectl plugin (macOS/Linux)
if [[ "$OSTYPE" == "darwin"* ]]; then
  brew install argoproj/tap/kubectl-argo-rollouts
else
  curl -LO "https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64"
  chmod +x kubectl-argo-rollouts-linux-amd64
  sudo mv kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts
fi

# Verify
kubectl rollout status deploy/argo-rollouts -n argo-rollouts
kubectl argo rollouts version

echo ""
echo "Argo Rollouts installed!"
echo ""
echo "Key commands:"
echo "  kubectl argo rollouts list rollouts -n production"
echo "  kubectl argo rollouts get rollout myapp --watch -n production"
echo "  kubectl argo rollouts promote myapp -n production     # approve canary"
echo "  kubectl argo rollouts abort myapp -n production       # rollback"
echo "  kubectl argo rollouts dashboard                        # open web UI"
