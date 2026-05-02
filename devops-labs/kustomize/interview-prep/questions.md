# Kustomize Interview Questions

## Q1. What is the difference between Kustomize and Helm?

| | Kustomize | Helm |
|-|-----------|------|
| Approach | Patching base YAML | Go template rendering |
| Learning | Easier (pure YAML) | Harder (Go template syntax) |
| Versioning | Git is the version | Chart versions + appVersion |
| Logic | Limited (patches only) | Full: loops, conditions, functions |
| Dependencies | Manual | Built-in `dependencies:` |
| Rollback | `git revert` | `helm rollback` |
| Best for | Your own apps, env differences | Distributable packages |

**Combined approach**: Use Helm for installing community charts (prometheus, nginx-ingress) and Kustomize for managing your own app's environment differences.

---

## Q2. What is a strategic merge patch vs JSON 6902 patch?

**Strategic merge patch**: Kubernetes-aware merging. Array elements matched by name.

```yaml
# Base has 3 containers, you only need to patch one:
patches:
- patch: |-
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: myapp
    spec:
      template:
        spec:
          containers:
          - name: app              # Matched by name, not index
            resources:
              limits:
                memory: "2Gi"
  target:
    kind: Deployment
```

**JSON 6902 patch**: RFC 6902 operations (add/remove/replace/copy/move) on exact paths.

```yaml
patches:
- target:
    kind: Deployment
    name: myapp
  patch: |-
    - op: replace
      path: /spec/replicas
      value: 10
    - op: add
      path: /spec/template/spec/containers/0/env/-
      value:
        name: NEW_VAR
        value: "value"
    - op: remove
      path: /spec/template/spec/containers/0/env/0
```

Use strategic merge for larger changes, JSON 6902 for surgical precision.

---

## Q3. How do ConfigMap generators work and why are they useful?

```yaml
configMapGenerator:
- name: app-config
  literals:
  - KEY=value
  files:
  - config.properties

# Kustomize generates:
# ConfigMap "app-config-6b4f9c2d7" (with hash suffix)

# The hash changes when ConfigMap content changes
# → Deployment that references it gets new hash in envFrom
# → Kubernetes triggers a rolling restart automatically!

# Without hash, you'd have to manually restart pods after ConfigMap changes.
```

Disable hash for ConfigMaps that shouldn't trigger restarts:
```yaml
generatorOptions:
  disableNameSuffixHash: true
```

---

## Q4. How do you handle image tags in a GitOps pipeline with Kustomize?

```bash
# Pattern 1: CI updates tag in Git, ArgoCD/Flux detects and deploys
# In GitHub Actions:
cd overlays/production
kustomize edit set image myapp=ghcr.io/myorg/myapp:${SHORT_SHA}
git commit -am "deploy: myapp ${SHORT_SHA}"
git push

# Pattern 2: Flux Image Automation (automatic)
# ImagePolicy watches registry for new tags
# ImageUpdateAutomation commits tag updates to Git automatically

# The kustomization.yaml marker for Flux:
# image: ghcr.io/myorg/myapp:v1.0.0 # {"$imagepolicy": "flux-system:myapp"}
```

---

## Q5. What are Kustomize components and when should you use them?

```yaml
# components/ are optional, reusable add-ons
# Different from overlays: they can be included in MULTIPLE overlays

# components/monitoring/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
patches:
- patch: |-
    - op: add
      path: /spec/template/metadata/annotations/prometheus.io~1scrape
      value: "true"
  target:
    kind: Deployment

# Use in any overlay:
# components:
# - ../../components/monitoring
# - ../../components/debug-sidecar   # Include only in staging

# vs Overlays: overlays are environment-specific (one per env)
# Components: cross-cutting concerns included in multiple environments
```

---

## Q6. How do you apply Kustomize in a monorepo?

```
gitops-repo/
  apps/
    service-a/
      base/ + overlays/staging/ + overlays/production/
    service-b/
      base/ + overlays/staging/ + overlays/production/
  clusters/
    staging/
      kustomization.yaml   ← includes all staging overlays
    production/
      kustomization.yaml   ← includes all production overlays

# clusters/production/kustomization.yaml
resources:
- ../../apps/service-a/overlays/production
- ../../apps/service-b/overlays/production
- ../../apps/service-c/overlays/production

# Single kubectl apply deploys everything:
kubectl apply -k clusters/production/
```

---

## Q7. How do you validate Kustomize output?

```bash
# 1. Syntax check
kustomize build . | kubectl apply --dry-run=client -f -

# 2. Schema validation
kustomize build . | kubeval --strict
# or
kustomize build . | kubeconform -

# 3. Policy validation (OPA/Conftest)
kustomize build . | conftest test -

# 4. Diff before applying
kubectl diff -k overlays/production/

# 5. In CI/CD
kustomize build overlays/$ENV/ | \
  kubectl apply --dry-run=server -f -  # Server-side dry run validates admission webhooks too
```

---

## Q8. How do you handle secrets in Kustomize?

```yaml
# ❌ Never commit plaintext secrets in kustomization.yaml

# ✅ Option 1: Sealed Secrets
# Generate sealed secret: kubeseal < secret.yaml > sealed-secret.yaml
# Commit sealed-secret.yaml to Git (encrypted with cluster key)
resources:
- sealed-secret.yaml   # Safe to commit

# ✅ Option 2: External Secrets Operator
# ExternalSecret CRD in Git → fetches from AWS/Vault at runtime
resources:
- external-secret.yaml  # References secret ARN/path, not the value

# ✅ Option 3: SOPS encrypted values (used by Flux)
# sops --encrypt secrets.yaml > secrets.enc.yaml
# Flux decrypts at sync time with age/pgp key in cluster
```

---

## Q9. What is the `namespace` field in kustomization.yaml?

```yaml
namespace: production
# Applied to ALL namespaced resources in the build output
# Overrides any namespace in the base manifests

# Exception: ClusterRole, ClusterRoleBinding, PersistentVolume
# (cluster-scoped resources ignore namespace)

# Per-resource namespace override:
patches:
- patch: |-
    - op: replace
      path: /metadata/namespace
      value: special-namespace
  target:
    kind: ServiceAccount
    name: special-sa
```

---

## Q10. How does Kustomize handle CRDs vs regular resources?

```yaml
# Problem: CRD must exist before resources that use it

# Solution 1: Deploy CRD first, then the CR
# Run in order:
# kubectl apply -f crds/
# kubectl apply -k overlays/production/

# Solution 2: Use resources ordering (crds first)
resources:
- crds/my-crd.yaml
- deployment.yaml
# Kustomize doesn't guarantee order, so this may not work reliably

# Solution 3: ArgoCD sync waves
# metadata:
#   annotations:
#     argocd.argoproj.io/sync-wave: "-10"  # CRD deploys first

# Solution 4: Helm chart handles CRD lifecycle
# helm install --set installCRDs=true
```

---

## Q11. Kustomize build fails with "no matches for kind". What happened?

```bash
# Error: no matches for kind "HorizontalPodAutoscaler" in version "autoscaling/v2beta2"

# Cause: API version in base/overlay doesn't match cluster's API version
# autoscaling/v2beta2 was removed in K8s 1.26

# Fix: Update the apiVersion in your manifests
# Old: apiVersion: autoscaling/v2beta2
# New: apiVersion: autoscaling/v2

# Or: use pluto to find deprecated APIs
pluto detect-files -d .
# Shows: DEPRECATED  autoscaling/v2beta2 HorizontalPodAutoscaler

# Run kustomize build and check API versions:
kustomize build . | grep apiVersion
```

---

## Q12. How do you reuse patches across multiple overlays?

```yaml
# Create a shared patches directory
# patches/
#   increase-replicas.yaml   ← reused by staging and production
#   add-monitoring.yaml

# overlays/staging/kustomization.yaml
patches:
- path: ../../patches/increase-replicas.yaml
  target:
    kind: Deployment

# overlays/production/kustomization.yaml  
patches:
- path: ../../patches/increase-replicas.yaml
  target:
    kind: Deployment
- path: ../../patches/add-monitoring.yaml

# Or use Components (cleaner):
components:
- ../../components/monitoring
- ../../components/production-resources
```

---

## Q13. How do you do a blue-green deployment with Kustomize?

```bash
# Kustomize doesn't have built-in traffic management
# But you can use name suffixes + Service selectors

# Blue deployment (current):
# overlays/blue/kustomization.yaml
nameSuffix: -blue
patches:
- patch: |-
    - op: add
      path: /spec/template/metadata/labels/version
      value: blue
  target:
    kind: Deployment

# Green deployment (new):
# overlays/green/kustomization.yaml
nameSuffix: -green
patches:
- patch: |-
    - op: add
      path: /spec/template/metadata/labels/version
      value: green
  target:
    kind: Deployment

# Switch traffic: update Service selector
# overlays/switch-to-green/
patches:
- patch: |-
    - op: replace
      path: /spec/selector/version
      value: green
  target:
    kind: Service
```

---

## Q14. What does `kustomize build | kubectl diff` show?

```bash
kubectl diff -k overlays/production/
# Shows what WOULD change in the cluster without applying
# Uses three-way merge between:
#   1. Last applied state
#   2. Current cluster state
#   3. New desired state (kustomize build output)

# Output:
# --- current
# +++ new
# @@ -5,6 +5,6 @@
# -  replicas: 3
# +  replicas: 5

# Use in CI to review changes before applying:
# kubectl diff -k overlays/production/ || echo "Changes detected"
```

---

## Q15. Kustomize vs Helm for a Platform Engineering team managing 50+ services?

```
Recommendation: Use both
  Helm for: nginx-ingress, cert-manager, prometheus, velero
            (community charts with complex configs)
  Kustomize for: your own apps (API, frontend, workers)
                 (simpler, no templating overhead)

GitOps workflow:
  1. Helm: ArgoCD Application with chart + values file
  2. Kustomize: ArgoCD Application with path to overlay
  3. App-of-Apps pattern manages all of the above

Scale with Kustomize at 50+ services:
  - Base templates (90% same across services)
  - Service-specific overlays (10% different)
  - Shared components for cross-cutting concerns
  - Single cluster/ directory deploys everything
  - CI only updates image tags, nothing else
```
