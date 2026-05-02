# Lab 01: GitOps with ArgoCD — Complete Setup

**Difficulty**: Intermediate | **Time**: 60 minutes  
**Goal**: Install ArgoCD, connect a GitOps repository, and deploy an app with automatic sync.

---

## Part 1: Install ArgoCD

```bash
# Create cluster
kind create cluster --name gitops-lab

# Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for all pods to be ready
kubectl wait --for=condition=Ready pod --all -n argocd --timeout=3m

# Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo

# Access the UI
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
echo "ArgoCD UI: https://localhost:8080 (admin / password above)"

# Install ArgoCD CLI
brew install argocd    # macOS
# Or download from: https://github.com/argoproj/argo-cd/releases

# Login via CLI
argocd login localhost:8080 --username admin --insecure
```

---

## Part 2: Create a GitOps Repository

### Option A: Fork an existing repo

```bash
# Fork https://github.com/argoproj/argocd-example-apps on GitHub
# Then use your fork URL
```

### Option B: Create your own GitOps repo

```bash
mkdir gitops-repo && cd gitops-repo
git init

# Application manifests (base)
mkdir -p apps/guestbook/base

cat > apps/guestbook/base/deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: guestbook-ui
  labels:
    app: guestbook-ui
spec:
  replicas: 2
  selector:
    matchLabels:
      app: guestbook-ui
  template:
    metadata:
      labels:
        app: guestbook-ui
    spec:
      containers:
      - name: guestbook-ui
        image: gcr.io/heptio-images/ks-guestbook-demo:0.1
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 128Mi
EOF

cat > apps/guestbook/base/service.yaml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: guestbook-ui
spec:
  selector:
    app: guestbook-ui
  ports:
  - port: 80
    targetPort: 80
EOF

cat > apps/guestbook/base/kustomization.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- deployment.yaml
- service.yaml
EOF

# Staging overlay
mkdir -p apps/guestbook/overlays/staging

cat > apps/guestbook/overlays/staging/kustomization.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- ../../base

namespace: staging

patches:
- patch: |-
    - op: replace
      path: /spec/replicas
      value: 1
  target:
    kind: Deployment
    name: guestbook-ui
EOF

# Production overlay
mkdir -p apps/guestbook/overlays/production

cat > apps/guestbook/overlays/production/kustomization.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- ../../base

namespace: production

patches:
- patch: |-
    - op: replace
      path: /spec/replicas
      value: 5
  target:
    kind: Deployment
    name: guestbook-ui

images:
- name: gcr.io/heptio-images/ks-guestbook-demo
  newTag: "0.2"
EOF

git add .
git commit -m "feat: add guestbook application manifests"

# Push to GitHub (create repo first)
git remote add origin https://github.com/YOUR_USERNAME/gitops-repo.git
git push -u origin main
cd ..
```

---

## Part 3: Create ArgoCD Application

### Via CLI

```bash
# Create namespaces
kubectl create namespace staging
kubectl create namespace production

# Create ArgoCD Application for staging
argocd app create guestbook-staging \
  --repo https://github.com/YOUR_USERNAME/gitops-repo \
  --path apps/guestbook/overlays/staging \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace staging \
  --sync-policy automated \
  --auto-prune \
  --self-heal \
  --project default

# Check status
argocd app get guestbook-staging
argocd app list
```

### Via YAML (declarative)

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: guestbook-production
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/YOUR_USERNAME/gitops-repo
    targetRevision: main
    path: apps/guestbook/overlays/production
  destination:
    server: https://kubernetes.default.svc
    namespace: production
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
    retry:
      limit: 3
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
EOF
```

---

## Part 4: Test GitOps Workflows

### Test automatic sync

```bash
# Make a change to the repo
cd gitops-repo

# Update replica count in staging
cat > apps/guestbook/overlays/staging/kustomization.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- ../../base
namespace: staging
patches:
- patch: |-
    - op: replace
      path: /spec/replicas
      value: 3    # Changed from 1 to 3
  target:
    kind: Deployment
    name: guestbook-ui
EOF

git add .
git commit -m "feat(staging): scale to 3 replicas"
git push

# Watch ArgoCD detect and apply the change (within 3 minutes)
watch argocd app get guestbook-staging
# STATUS changes: Synced → OutOfSync → Synced (after auto-sync)

kubectl get pods -n staging -w
# New pods appear!
```

### Test self-healing

```bash
# Manually change something in K8s (ArgoCD should revert it)
kubectl scale deployment/guestbook-ui -n staging --replicas=10

# ArgoCD detects drift and reverts to Git state (replicas=3)
watch kubectl get pods -n staging
# Should go back to 3 pods within a few minutes
```

### Test rollback

```bash
# If a deploy is bad, revert in Git → ArgoCD handles the rest
cd gitops-repo

# Revert the change
git revert HEAD
git push

# Or manually sync to a specific revision:
argocd app sync guestbook-staging --revision abc1234
```

---

## Part 5: App-of-Apps Pattern

```bash
# Create a "root app" that manages all other apps
cat << 'EOF' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/YOUR_USERNAME/gitops-repo
    targetRevision: main
    path: clusters/staging    # Contains Application YAML files
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

# Now add Application manifests to clusters/staging/
mkdir -p gitops-repo/clusters/staging
cat > gitops-repo/clusters/staging/guestbook.yaml << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: guestbook
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/YOUR_USERNAME/gitops-repo
    targetRevision: main
    path: apps/guestbook/overlays/staging
  destination:
    server: https://kubernetes.default.svc
    namespace: staging
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

cd gitops-repo
git add . && git commit -m "feat: app-of-apps pattern" && git push
```

---

## Cleanup

```bash
argocd app delete guestbook-staging --cascade
argocd app delete guestbook-production --cascade
kind delete cluster --name gitops-lab
```

## What You Learned

- [x] ArgoCD installation and CLI usage
- [x] GitOps repository structure with Kustomize overlays
- [x] Automatic sync: Git change → cluster update
- [x] Self-healing: manual change → ArgoCD reverts
- [x] Declarative Application YAML
- [x] App-of-Apps pattern for managing multiple applications
