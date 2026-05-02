# GitOps Concepts

## Push vs Pull Model

```
Push-based (Traditional CI/CD):
  Git push → CI/CD pipeline → kubectl apply → Cluster
  Problem: CI/CD system needs cluster credentials
           Cluster state can drift from Git (someone runs kubectl manually)

Pull-based (GitOps):
  Git push → ArgoCD/Flux detects change → Pulls from Git → Applies to cluster
  Benefit:  No external credentials needed
            Cluster reconciles itself to Git state continuously
            Drift detected and auto-corrected
```

---

## Repository Structure

```
gitops-repo/
├── apps/
│   ├── my-api/
│   │   ├── base/                  # Common K8s manifests
│   │   │   ├── deployment.yaml
│   │   │   ├── service.yaml
│   │   │   └── kustomization.yaml
│   │   └── overlays/
│   │       ├── staging/
│   │       │   ├── kustomization.yaml  # staging-specific patches
│   │       │   └── replica-patch.yaml
│   │       └── production/
│   │           ├── kustomization.yaml  # prod-specific patches
│   │           └── replica-patch.yaml
│   └── postgres/
│       └── ...
├── clusters/
│   ├── staging/
│   │   └── apps.yaml              # ArgoCD ApplicationSet or Flux Kustomization
│   └── production/
│       └── apps.yaml
└── infrastructure/
    ├── cert-manager/
    ├── ingress-nginx/
    └── monitoring/
```

---

## ArgoCD Application CRD

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-api-production
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io   # Cascade delete on app delete
spec:
  project: production

  source:
    repoURL: https://github.com/myorg/gitops
    targetRevision: main
    path: apps/my-api/overlays/production

  destination:
    server: https://kubernetes.default.svc
    namespace: production

  syncPolicy:
    automated:
      prune: true        # Delete resources removed from Git
      selfHeal: true     # Revert manual kubectl changes
    syncOptions:
    - CreateNamespace=true
    - RespectIgnoreDifferences=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m

  # Ignore HPA-managed replica count
  ignoreDifferences:
  - group: apps
    kind: Deployment
    jsonPointers:
    - /spec/replicas
```

---

## ArgoCD ApplicationSet (Multi-cluster, Multi-env)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: my-api
  namespace: argocd
spec:
  generators:
  # Deploy to all environments from a list
  - list:
      elements:
      - env: staging
        cluster: staging-cluster
        url: https://staging-k8s-api.company.com
      - env: production
        cluster: production-cluster
        url: https://prod-k8s-api.company.com

  # Or from Git: creates an app per directory found
  # - git:
  #     repoURL: https://github.com/myorg/gitops
  #     revision: main
  #     directories:
  #     - path: apps/*/overlays/*

  template:
    metadata:
      name: '{{env}}-my-api'
    spec:
      project: '{{env}}'
      source:
        repoURL: https://github.com/myorg/gitops
        targetRevision: main
        path: 'apps/my-api/overlays/{{env}}'
      destination:
        server: '{{url}}'
        namespace: production
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
```

---

## Flux (Alternative to ArgoCD)

```yaml
# GitRepository — where to pull from
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: gitops-repo
  namespace: flux-system
spec:
  interval: 1m
  url: https://github.com/myorg/gitops
  ref:
    branch: main
  secretRef:
    name: flux-system   # SSH key or token

---
# Kustomization — what to apply
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: my-api-production
  namespace: flux-system
spec:
  interval: 5m                  # Reconcile every 5 minutes
  path: ./apps/my-api/overlays/production
  prune: true                   # Delete orphaned resources
  sourceRef:
    kind: GitRepository
    name: gitops-repo
  healthChecks:
  - apiVersion: apps/v1
    kind: Deployment
    name: my-api
    namespace: production
  postBuild:
    substitute:
      IMAGE_TAG: "${IMAGE_TAG}"  # Substitute variables from ConfigMap/Secret
    substituteFrom:
    - kind: ConfigMap
      name: cluster-vars

---
# ImageUpdateAutomation — auto-update image tags in Git
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageUpdateAutomation
metadata:
  name: my-api-automation
  namespace: flux-system
spec:
  interval: 5m
  sourceRef:
    kind: GitRepository
    name: gitops-repo
  git:
    commit:
      author:
        email: fluxcdbot@company.com
        name: Flux CD Bot
      messageTemplate: 'chore: update my-api to {{.Updated.Images}}'
    push:
      branch: main
  update:
    path: ./apps/my-api/overlays/production
    strategy: Setters
```

---

## CI Workflow with GitOps

```
Step 1: Developer pushes code → GitHub
Step 2: GitHub Actions: test → build → push image to GHCR
Step 3: GitHub Actions: update image tag in gitops repo
         (git commit -m "chore: update my-api to abc1234")
Step 4: ArgoCD/Flux detects change in gitops repo
Step 5: ArgoCD/Flux applies updated manifests to cluster
Step 6: Deployment rolls out
Step 7: ArgoCD/Flux reports health

# GitHub Actions step to update gitops repo:
- name: Update image tag in GitOps repo
  run: |
    git clone https://x-access-token:${{ secrets.GITOPS_TOKEN }}@github.com/myorg/gitops
    cd gitops
    # Update the image tag using kustomize
    cd apps/my-api/overlays/production
    kustomize edit set image myapp=ghcr.io/myorg/myapp:$IMAGE_TAG
    git config user.email "ci@company.com"
    git config user.name "GitHub Actions"
    git add .
    git commit -m "chore: update my-api to $IMAGE_TAG [skip ci]"
    git push
```
