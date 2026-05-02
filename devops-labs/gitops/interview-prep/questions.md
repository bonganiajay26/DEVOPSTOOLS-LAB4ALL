# GitOps Interview Questions

## Q1. What is GitOps and how is it different from traditional CI/CD?

```
Traditional CI/CD (push-based):
  Developer → Git → CI builds → CI pushes to cluster
  Problems:
  - CI needs cluster credentials
  - No drift detection (manual changes persist)
  - Rollback = re-run old pipeline

GitOps (pull-based):
  Developer → Git → Agent detects change → Agent pulls and applies
  Benefits:
  - No external credential access
  - Auto-drift correction (SelfHeal)
  - Rollback = git revert
  - Full audit trail in Git
  - Single source of truth
```

---

## Q2. ArgoCD vs Flux — when to choose each?

| | ArgoCD | Flux |
|-|--------|------|
| UI | Rich, built-in web UI | Grafana dashboard optional |
| Multi-cluster | Strong (ApplicationSets) | Supported |
| Image automation | Needs external tooling | Built-in ImageUpdateAutomation |
| K8s native | Partially (CRDs) | Fully K8s native (just CRDs) |
| RBAC | Rich app-level RBAC | K8s RBAC only |
| Complexity | Medium | Low-Medium |
| Best for | Teams wanting GUI, multi-cluster | K8s-native automation, GitOps for infra too |

---

## Q3. How does drift detection and self-healing work?

```
ArgoCD checks every 3 minutes (default):
1. Fetch current K8s state (kubectl get)
2. Render desired state from Git
3. Compare: any difference = DRIFT
4. If selfHeal=true: automatically applies Git state
5. If selfHeal=false: shows OutOfSync status in UI

Example:
  Someone runs: kubectl scale deployment api --replicas=10
  ArgoCD sees: desired=3 (from Git), actual=10 → OutOfSync
  If selfHeal: scales back to 3 automatically (within 3 min)

# Prevent accidental self-heal during HPA:
spec:
  ignoreDifferences:
  - group: apps
    kind: Deployment
    jsonPointers:
    - /spec/replicas    # Ignore HPA-managed replica count
```

---

## Q4. How do you implement multi-environment promotion with GitOps?

```
gitops-repo/
  apps/my-api/overlays/
    staging/      → deploys automatically on merge
    production/   → deploys on manual PR approval

Pipeline:
1. CI builds image, pushes to GHCR
2. CI opens PR: "Update my-api in staging to abc1234"
3. PR auto-merges → ArgoCD deploys to staging
4. QA runs automated tests
5. CI opens second PR: "Promote my-api to production (abc1234)"
6. Human reviews and approves PR
7. Merge → ArgoCD deploys to production

# Staging kustomization.yaml
images:
- name: ghcr.io/myorg/my-api
  newTag: abc1234    # Updated by CI for staging
  
# Production kustomization.yaml
images:
- name: ghcr.io/myorg/my-api
  newTag: abc1234    # Updated by separate promotion PR
```

---

## Q5. How do you manage secrets in a GitOps workflow?

```bash
# Option 1: Sealed Secrets (encrypt in Git, decrypt in cluster)
# Install Sealed Secrets controller
helm install sealed-secrets sealed-secrets/sealed-secrets -n kube-system

# Create sealed secret
kubeseal < plain-secret.yaml > sealed-secret.yaml
# sealed-secret.yaml is safe to commit to Git!
kubectl apply -f sealed-secret.yaml

# Option 2: External Secrets Operator (pull from Vault/AWS SM)
# ExternalSecret CRD in Git → operator fetches real secret from Vault
# Secret never in Git, pulled at runtime

# Option 3: Flux SOPS integration
# Encrypt values with Age/GPG keys
# sops --encrypt --age $(cat age.pub) secrets.yaml > secrets.enc.yaml
# Flux decrypts automatically with the private key (in-cluster Secret)

# Option 4: ArgoCD Vault Plugin
# Use {{vault:secret/path#key}} placeholders in manifests
# Plugin fetches from Vault at sync time
```

---

## Q6. ArgoCD app is OutOfSync but sync fails. How do you debug?

```bash
# 1. Check ArgoCD UI → Application → Events tab

# 2. CLI inspection
argocd app get my-api
argocd app diff my-api          # What's different between Git and cluster?

# 3. Common causes:
# Validation error: bad YAML
argocd app sync my-api --dry-run  # Preview without applying

# Namespace doesn't exist
kubectl create namespace production

# RBAC: ArgoCD SA lacks permission
kubectl auth can-i create deployments --as=system:serviceaccount:argocd:argocd-application-controller -n production

# Helm chart dependency not downloaded
argocd app sync my-api --replace  # Force replace (use carefully)

# Resource stuck in Terminating
kubectl delete pod stuck-pod -n production --force --grace-period=0

# 4. Force refresh (if using OCI/Helm registry caching)
argocd app get my-api --hard-refresh
```

---

## Q7. How do you handle a rollback in GitOps?

```bash
# GitOps rollback = Git revert (creates new commit)
# This keeps Git as source of truth

# Option 1: Git revert
cd gitops-repo
git revert HEAD                  # Revert last commit
git push origin main             # ArgoCD picks up automatically

# Option 2: ArgoCD UI rollback
argocd app rollback my-api 5     # Roll back to revision 5
# This creates a one-off sync — GitOps repo still has new version
# Next ArgoCD sync will re-apply new version!
# For permanent rollback, revert the Git commit.

# Option 3: Rollback image only
cd apps/my-api/overlays/production
kustomize edit set image myapp=ghcr.io/myorg/myapp:PREVIOUS_TAG
git commit -am "revert: rollback my-api to vPREVIOUS_TAG"
git push
```

---

## Q8. What is a GitOps repository split? Mono-repo vs poly-repo?

```
Mono-repo (one repo for all apps + infrastructure):
  gitops/
    apps/
      service-a/
      service-b/
    infrastructure/
  ✅ Single PR shows all changes together
  ✅ Easy cross-service changes
  ❌ Access control: all teams see all code
  ❌ Large repos slow down

Poly-repo (separate repo per concern):
  gitops-infra/       → platform team owns
  gitops-apps-team-a/ → team A owns
  gitops-apps-team-b/ → team B owns
  ✅ Clear ownership, isolated access
  ✅ Faster per-team
  ❌ Cross-team changes need multiple PRs

Hybrid (recommended):
  infra-gitops/   → platform engineering
  app-gitops/     → all app teams, team-based directories
    teams/team-a/
    teams/team-b/
```

---

## Q9. How does ArgoCD handle Helm charts in GitOps?

```yaml
# Option 1: Helm chart from repository
spec:
  source:
    repoURL: https://charts.bitnami.com/bitnami
    chart: postgresql
    targetRevision: "13.4.0"   # Pin chart version!
    helm:
      values: |
        auth:
          password: "notreal"
      valuesObject:
        primary:
          persistence:
            size: 20Gi

# Option 2: Helm chart from Git (rendered server-side)
spec:
  source:
    repoURL: https://github.com/myorg/gitops
    path: charts/my-api
    targetRevision: main
    helm:
      valueFiles:
      - values-production.yaml
      parameters:
      - name: image.tag
        value: abc1234
```

---

## Q10. What is the difference between ArgoCD `Application` and `AppProject`?

```yaml
# AppProject — defines what an Application CAN do
# Security boundary for multi-tenant ArgoCD

apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: team-alpha
  namespace: argocd
spec:
  description: Team Alpha applications
  sourceRepos:
  - https://github.com/myorg/team-alpha-gitops   # Only these repos
  destinations:
  - namespace: team-alpha-*    # Only deploy to team-alpha-* namespaces
    server: https://kubernetes.default.svc
  clusterResourceWhitelist: []   # Can't touch cluster-wide resources
  namespaceResourceWhitelist:
  - group: apps
    kind: Deployment
  - group: ""
    kind: Service             # Can only create Deployments and Services

# Application — actual sync target, must belong to a project
spec:
  project: team-alpha         # Must match AppProject name
```

---

## Q11. How do you deal with ordered deployment (App-of-Apps pattern)?

```yaml
# Problem: some apps must deploy before others
# (e.g., cert-manager before apps using certificates)

# Solution: App-of-Apps pattern
# Root app manages all other apps' ArgoCD Application objects

# Root application
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-app
spec:
  source:
    path: clusters/production    # Contains ArgoCD Application YAML files
  syncPolicy:
    automated:
      prune: true
      selfHeal: true

# clusters/production/cert-manager.yaml → ArgoCD Application for cert-manager
# clusters/production/ingress.yaml      → ArgoCD Application for ingress (depends on cert-manager)
# clusters/production/my-api.yaml       → ArgoCD Application for API

# Sync waves (order within a sync):
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-1"   # Deploy first
# cert-manager: wave -1
# crds: wave -1
# ingress: wave 0
# apps: wave 1

# Sync hooks (run scripts between waves):
metadata:
  annotations:
    argocd.argoproj.io/hook: Sync
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
```

---

## Q12. How do you monitor ArgoCD itself?

```bash
# ArgoCD exposes Prometheus metrics
kubectl port-forward svc/argocd-metrics 8082:8082 -n argocd

# Key metrics:
# argocd_app_info                    → app count per health/sync status
# argocd_app_sync_total              → sync attempts (success/failure)
# argocd_app_k8s_request_total       → K8s API calls by ArgoCD
# argocd_cluster_events_total        → cluster events processed

# Alert: app out of sync for too long
- alert: ArgoCDAppOutOfSync
  expr: |
    argocd_app_info{sync_status="OutOfSync"} == 1
  for: 30m
  annotations:
    summary: "ArgoCD app {{ $labels.name }} out of sync for 30 minutes"
```

---

## Q13. How does GitOps support compliance and auditing?

```
Audit trail benefits:
1. Who changed what and when → git log
2. Why was it changed → commit message + PR description
3. Who approved → PR review history
4. Can reproduce exact state → git checkout <sha>
5. Automatic change tracking → all changes go through PR process

Compliance features:
- Branch protection: no direct commits to main
- Required reviews: minimum 2 approvers for production
- Signed commits: GPG signatures verify author identity
- CODEOWNERS: specific teams must approve infrastructure changes
- Change management: PR = Change Request (ITIL compliance)

# CODEOWNERS example:
# .github/CODEOWNERS
apps/my-api/overlays/production    @platform-team @security-team
infrastructure/                    @platform-team
clusters/production/               @platform-team @ciso
```

---

## Q14. What is Image Updater / Flux Image Automation?

```yaml
# Flux Image Automation: monitors registry, updates image tags in Git automatically

# 1. ImageRepository: watch for new images
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageRepository
metadata:
  name: my-api
  namespace: flux-system
spec:
  image: ghcr.io/myorg/my-api
  interval: 1m
  secretRef:
    name: ghcr-credentials

# 2. ImagePolicy: which tags to use (semver, regex, alphabetical)
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImagePolicy
metadata:
  name: my-api-policy
spec:
  imageRepositoryRef:
    name: my-api
  policy:
    semver:
      range: ">=1.0.0"    # Auto-update to latest semver (not pre-release)

# 3. Mark where to update in manifest:
# deployment.yaml
# image: ghcr.io/myorg/my-api:1.2.3 # {"$imagepolicy": "flux-system:my-api"}

# 4. ImageUpdateAutomation: commit updated tag to Git
# Flux detects policy violation → updates file → commits → Flux reconciles
```

---

## Q15. What are the challenges of GitOps at scale?

```
Challenge 1: Repository size
  Large number of apps → slow git clone/fetch
  Solution: sparse checkout, shallow clones, multiple repos

Challenge 2: Secret management
  Can't store secrets in Git
  Solution: Sealed Secrets, External Secrets, SOPS

Challenge 3: PR volume
  Automated image updates create many PRs
  Solution: Batch updates, auto-merge for staging, human review for prod

Challenge 4: Debugging
  Multi-layer abstraction: Git → ArgoCD → K8s
  Solution: Good observability, ArgoCD UI, clear error messages

Challenge 5: Bootstrap problem
  How do you install ArgoCD if ArgoCD manages itself?
  Solution: Helm install ArgoCD first, then let it manage its own config

Challenge 6: Cross-cutting changes
  Same change needed in 20 microservices
  Solution: ApplicationSets, automated PR creation (renovate bot, custom scripts)

Challenge 7: Drift in infrastructure (Terraform)
  Terraform state vs Git
  Solution: Atlantis (Terraform GitOps), or Crossplane (K8s-native infra)
```
