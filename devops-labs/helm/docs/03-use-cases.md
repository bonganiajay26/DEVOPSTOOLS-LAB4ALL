# Helm Real-World Use Cases

## 1. Multi-Tier Application Deployment

```bash
# Deploy a full stack: app + postgres + redis using one command
helm install myapp ./myapp-chart \
  --set image.tag=v2.1.0 \
  --set postgresql.enabled=true \
  --set postgresql.auth.password=secretpass \
  --set redis.enabled=true \
  -n production --create-namespace

# All three components come up in correct order (postgres first via init containers)
```

---

## 2. GitOps with Helm + ArgoCD

```yaml
# ArgoCD Application using a Helm chart from OCI registry
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp-production
  namespace: argocd
spec:
  source:
    repoURL: oci://ghcr.io/myorg/charts
    chart: myapp
    targetRevision: "2.1.0"    # Pin chart version!
    helm:
      valueFiles:
      - values-production.yaml  # From same GitOps repo
      parameters:
      - name: image.tag
        value: abc1234           # Injected by CI
  destination:
    server: https://kubernetes.default.svc
    namespace: production
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

---

## 3. Progressive Delivery with Helm

```bash
# Stage 1: Install canary (10% traffic via ingress weights)
helm install myapp-canary ./mychart \
  --set replicaCount=1 \
  --set ingress.weight=10 \
  --set image.tag=v2.0.0 \
  -n production

# Stage 2: Validate metrics (check error rate, latency)
# If ok → Stage 3: Full rollout
helm upgrade myapp ./mychart \
  --set image.tag=v2.0.0 \
  --set ingress.weight=100 \
  -n production

# Remove canary
helm uninstall myapp-canary -n production
```

---

## 4. Environment Promotion Pipeline

```bash
# CI/CD: build image → deploy to staging → gate → deploy to production

# Step 1: Deploy to staging (auto)
helm upgrade --install myapp ./mychart \
  -f values.yaml \
  -f environments/staging.yaml \
  --set image.tag=$IMAGE_TAG \
  -n staging \
  --atomic --wait --timeout 5m

# Step 2: Run integration tests
pytest tests/integration/ --base-url https://staging.company.com

# Step 3: Deploy to production (after human approval)
helm upgrade --install myapp ./mychart \
  -f values.yaml \
  -f environments/production.yaml \
  --set image.tag=$IMAGE_TAG \
  -n production \
  --atomic --wait --timeout 10m

# Step 4: Post-deploy verification
helm test myapp -n production
```

---

## 5. Managing Third-Party Tools with Helm

```bash
# Install the full observability stack with a single command
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f monitoring-values.yaml

# Cert-manager
helm repo add jetstack https://charts.jetstack.io
helm install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace \
  --set installCRDs=true

# ArgoCD
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd --create-namespace \
  -f argocd-values.yaml

# Keeping all of these in a helmfile.yaml makes updates easy:
# helmfile diff    # see what would change
# helmfile apply   # update all charts
```
