# Lab 02: GitOps with Flux — Image Automation and Multi-Cluster

**Difficulty**: Advanced | **Time**: 60 minutes  
**Goal**: Install Flux, configure image automation, and manage multiple environments.

---

## Part 1: Bootstrap Flux

```bash
# Prerequisites: GitHub account, kind cluster
kind create cluster --name flux-lab

# Install Flux CLI
brew install fluxcd/tap/flux    # macOS
# or: curl -s https://fluxcd.io/install.sh | bash

# Check prerequisites
flux check --pre

# Bootstrap Flux onto the cluster (connects to GitHub)
export GITHUB_TOKEN=<your-github-token>
export GITHUB_USER=<your-username>

flux bootstrap github \
  --owner=$GITHUB_USER \
  --repository=gitops-flux-lab \
  --branch=main \
  --path=./clusters/lab \
  --personal \
  --components-extra=image-reflector-controller,image-automation-controller

# Verify installation
flux check
kubectl get pods -n flux-system
# NAME                                       READY
# helm-controller-xxx                        1/1 Running
# image-automation-controller-xxx            1/1 Running
# image-reflector-controller-xxx             1/1 Running
# kustomize-controller-xxx                   1/1 Running
# notification-controller-xxx               1/1 Running
# source-controller-xxx                      1/1 Running
```

---

## Part 2: Configure a GitRepository Source

```bash
# Clone the newly created gitops repo
git clone https://github.com/$GITHUB_USER/gitops-flux-lab
cd gitops-flux-lab

# Create app namespace and manifests
mkdir -p apps/nginx/{base,overlays/lab}

cat > apps/nginx/base/deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:1.24-alpine  # {"$imagepolicy": "flux-system:nginx-policy"}
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
EOF

cat > apps/nginx/base/service.yaml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: nginx
  namespace: default
spec:
  selector:
    app: nginx
  ports:
  - port: 80
    targetPort: 80
EOF

cat > apps/nginx/base/kustomization.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- deployment.yaml
- service.yaml
EOF

cat > apps/nginx/overlays/lab/kustomization.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- ../../base
namespace: default
EOF

# Create Flux Kustomization to track the app
cat > clusters/lab/apps.yaml << 'EOF'
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: nginx-app
  namespace: flux-system
spec:
  interval: 5m
  sourceRef:
    kind: GitRepository
    name: flux-system   # Points to our gitops repo (created by bootstrap)
  path: ./apps/nginx/overlays/lab
  prune: true
  healthChecks:
  - apiVersion: apps/v1
    kind: Deployment
    name: nginx
    namespace: default
EOF

git add .
git commit -m "feat: add nginx app and Flux Kustomization"
git push

# Watch Flux reconcile
flux get kustomizations --watch
# After a minute, nginx should be deployed!
kubectl get pods
```

---

## Part 3: Image Automation — Auto-update Tags

```bash
# Create ImageRepository to watch Docker Hub
cat > clusters/lab/image-policy.yaml << 'EOF'
# Watch nginx image for new tags
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageRepository
metadata:
  name: nginx
  namespace: flux-system
spec:
  image: nginx
  interval: 5m
  # For private registries, add secretRef here

---
# Policy: use latest 1.x.x semver
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImagePolicy
metadata:
  name: nginx-policy
  namespace: flux-system
spec:
  imageRepositoryRef:
    name: nginx
  filterTags:
    pattern: '^(\d+\.\d+)-alpine$'
    extract: '$1'
  policy:
    semver:
      range: '>=1.24.0'

---
# Auto-commit updated image tags to Git
apiVersion: image.toolkit.fluxcd.io/v1beta1
kind: ImageUpdateAutomation
metadata:
  name: flux-system
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: flux-system
  git:
    checkout:
      ref:
        branch: main
    commit:
      author:
        email: fluxcdbot@company.com
        name: Flux CD
      messageTemplate: 'chore(image): update {{range .Updated.Images}}{{.}}{{end}}'
    push:
      branch: main
  update:
    path: ./apps
    strategy: Setters
EOF

git add clusters/lab/image-policy.yaml
git commit -m "feat: add image automation"
git push

# Wait for Flux to pick it up
flux get image repositories
flux get image policies
flux get image updateautomations

# Check what tag is being tracked
flux get image policies nginx-policy
```

---

## Part 4: Flux Notifications (Slack)

```bash
cat > clusters/lab/notifications.yaml << 'EOF'
# Slack notification provider
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Provider
metadata:
  name: slack
  namespace: flux-system
spec:
  type: slack
  channel: '#deployments'
  secretRef:
    name: slack-url

---
# Alert on sync events
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Alert
metadata:
  name: deployment-alerts
  namespace: flux-system
spec:
  providerRef:
    name: slack
  eventSeverity: info
  eventSources:
  - kind: Kustomization
    name: '*'              # All kustomizations
  - kind: HelmRelease
    name: '*'
  summary: "Flux sync event in lab cluster"
EOF

# Create the Slack webhook secret
kubectl create secret generic slack-url \
  --from-literal=address=https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK \
  -n flux-system

git add clusters/lab/notifications.yaml
git commit -m "feat: add Slack notifications"
git push
```

---

## Part 5: Multi-Environment with Flux

```bash
# Structure for multiple clusters
mkdir -p clusters/{staging,production}

# Staging: sync every 1 minute, auto-prune
cat > clusters/staging/nginx-app.yaml << 'EOF'
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: nginx-app
  namespace: flux-system
spec:
  interval: 1m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./apps/nginx/overlays/staging
  prune: true
  postBuild:
    substituteFrom:
    - kind: ConfigMap
      name: cluster-vars
EOF

# Production: sync every 5 minutes, requires manual reconcile for changes
cat > clusters/production/nginx-app.yaml << 'EOF'
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: nginx-app
  namespace: flux-system
  annotations:
    # Pause auto-sync for production (manual promotion required)
    # kustomize.toolkit.fluxcd.io/reconcile: disabled
spec:
  interval: 5m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./apps/nginx/overlays/production
  prune: false   # Extra safety: don't auto-delete in production
  healthChecks:
  - apiVersion: apps/v1
    kind: Deployment
    name: nginx
    namespace: production
EOF

git add .
git commit -m "feat: multi-environment Flux configuration"
git push

# Force manual reconcile (useful for production)
flux reconcile kustomization nginx-app --with-source
```

---

## Cleanup

```bash
kind delete cluster --name flux-lab
cd ..
```

## What You Learned

- [x] Flux bootstrap via GitHub
- [x] GitRepository and Kustomization resources
- [x] ImageRepository + ImagePolicy for version tracking
- [x] ImageUpdateAutomation for auto-commit of image tags
- [x] Flux Notifications via Slack
- [x] Multi-environment configuration with different sync policies
