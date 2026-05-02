# Helm Interview Questions

## Q1. What is Helm and what problem does it solve?

Helm is the package manager for Kubernetes. It solves:
- **Templating**: DRY — one chart, multiple environments via values
- **Versioning**: Chart versions + app versions, rollback with history
- **Dependency management**: Declare dependencies (postgresql, redis) in Chart.yaml
- **Release management**: Track what's deployed, upgrade/rollback atomically

```bash
# Without Helm: 15 YAML files, manually change image tag in each env
# With Helm: one chart, two values files
helm upgrade --install myapp ./chart -f values-prod.yaml --set image.tag=$NEW_TAG
```

---

## Q2. What is the difference between `helm install` and `helm upgrade --install`?

```bash
# helm install: fails if release already exists
helm install my-release ./chart

# helm upgrade --install: creates if not exists, upgrades if exists
# Idempotent — safe to run in CI/CD pipelines
helm upgrade --install my-release ./chart -f values.yaml

# Also useful flags:
# --atomic: rollback automatically if upgrade fails
# --cleanup-on-fail: delete new resources created during failed upgrade
# --wait: wait for all pods to be ready before marking as succeeded
# --timeout: how long to wait (default 5m)
helm upgrade --install my-release ./chart \
  --atomic \
  --wait \
  --timeout 10m \
  -f values.yaml
```

---

## Q3. How does Helm track releases?

Helm stores release state as Secrets in the cluster namespace:
```bash
kubectl get secrets -n production | grep helm
# sh.helm.release.v1.my-release.v1   helm.sh/release.v1
# sh.helm.release.v1.my-release.v2   helm.sh/release.v1

helm history my-release -n production
# REVISION  STATUS     CHART            APP VERSION  DESCRIPTION
# 1         superseded my-api-1.0.0     2.0.0        Install complete
# 2         deployed   my-api-1.1.0     2.1.0        Upgrade complete
```

---

## Q4. What is the `checksum/config` annotation pattern?

```yaml
# In deployment template:
metadata:
  annotations:
    checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
```

When a ConfigMap changes, the checksum changes, forcing a rolling restart of the Deployment. Without this, pods keep running with old config even after `helm upgrade`.

---

## Q5. How do you manage secrets in Helm?

```bash
# Option 1: Helm Secrets plugin (encrypts values.yaml with SOPS/gpg)
helm plugin install https://github.com/jkroepke/helm-secrets
helm secrets encrypt secrets.yaml     # Encrypts with .sops.yaml key config
helm upgrade --install my-app ./chart \
  -f values.yaml \
  -f secrets://secrets.encrypted.yaml  # Decrypts on-the-fly

# Option 2: External Secrets Operator (create ExternalSecret in templates/)
# Secrets pulled from AWS Secrets Manager/Vault at deploy time

# Option 3: --set with CI/CD environment variables (values not in repo)
helm upgrade --install my-app ./chart \
  --set database.password=$DATABASE_PASSWORD

# ❌ Never put plaintext secrets in values.yaml committed to git
```

---

## Q6. What are Helm hooks and what are common use cases?

```
Hook annotations:
  pre-install    → before resources are created
  post-install   → after all resources are ready
  pre-upgrade    → before upgrade starts
  post-upgrade   → after upgrade completes
  pre-rollback   → before rollback
  post-rollback  → after rollback
  pre-delete     → before uninstall
  test           → only when running `helm test`

Common use cases:
  pre-upgrade: database migrations
  pre-install: create namespace labels, initialize data
  post-install: send Slack notification, seed database
  test: run smoke tests against deployed app
```

---

## Q7. How do you roll back a failed Helm release?

```bash
# Check history
helm history my-release -n production
# REVISION 3 FAILED

# Roll back to previous revision
helm rollback my-release -n production  # Previous revision
helm rollback my-release 2 -n production  # Specific revision

# Auto-rollback on failure (recommended)
helm upgrade --install my-release ./chart --atomic

# Check status after rollback
helm status my-release -n production
```

---

## Q8. How do you structure Helm values for multiple environments?

```
charts/my-api/
├── values.yaml              # Defaults (minimal, safe values)
├── values-dev.yaml          # Dev overrides
├── values-staging.yaml      # Staging overrides
└── values-prod.yaml         # Production overrides

# Layered override (later files win):
helm upgrade --install my-api ./my-api \
  -f values.yaml \
  -f values-prod.yaml \
  --set image.tag=$(git rev-parse --short HEAD)

# values.yaml (defaults)
replicaCount: 1
autoscaling: { enabled: false }

# values-prod.yaml (prod overrides)
replicaCount: 5
autoscaling: { enabled: true, minReplicas: 5, maxReplicas: 50 }
```

---

## Q9. What is `helm dependency update`?

```yaml
# Chart.yaml
dependencies:
- name: postgresql
  version: "~13.4"
  repository: https://charts.bitnami.com/bitnami
  condition: postgresql.enabled

- name: redis
  version: "~18.0"
  repository: https://charts.bitnami.com/bitnami
  condition: redis.enabled
```

```bash
helm dependency update ./my-chart
# Downloads dependency charts into charts/ directory
# Creates Chart.lock for reproducible builds

helm dependency list ./my-chart
```

---

## Q10. How do you test a Helm chart?

```bash
# 1. Lint (syntax check)
helm lint ./my-chart/

# 2. Template rendering (no cluster needed)
helm template my-release ./my-chart -f values-prod.yaml | kubectl apply --dry-run=client -f -

# 3. Helm unittest (unit tests for templates)
helm plugin install https://github.com/helm-unittest/helm-unittest
helm unittest ./my-chart/

# 4. helm test (post-deploy smoke tests)
# templates/tests/test-connection.yaml:
# annotations: "helm.sh/hook": test
# containers: - name: test; command: ["curl", "-sf", "http://my-release/health"]
helm test my-release -n production

# 5. ct (Chart Testing — for chart repos with multiple charts)
ct lint && ct install
```

---

## Q11. What is the difference between a Helm chart `version` and `appVersion`?

```yaml
# Chart.yaml
version: 1.3.0      # Chart version — changes when TEMPLATES change
appVersion: "2.4.1" # App version being packaged — cosmetic label only

# Separate versioning allows:
# - Fix a template bug → bump chart version 1.3.0 → 1.3.1, appVersion unchanged
# - New app release → bump appVersion, chart structure unchanged
```

---

## Q12. How do you publish a Helm chart to a registry?

```bash
# Method 1: OCI registry (modern — GitHub Container Registry, ECR)
helm package ./my-chart
helm push my-chart-1.0.0.tgz oci://ghcr.io/myorg/charts
helm install my-release oci://ghcr.io/myorg/charts/my-chart --version 1.0.0

# Method 2: chart-releaser for GitHub Pages (classic)
# .github/workflows/release.yml
- uses: helm/chart-releaser-action@v1.6.0
  with:
    charts_dir: charts
  env:
    CR_TOKEN: ${{ secrets.GITHUB_TOKEN }}

# Method 3: Chartmuseum (self-hosted)
helm repo add my-charts http://chartmuseum.internal
```

---

## Q13. Explain the `{{- }}` syntax in Helm templates.

```
{{  }} = insert result
{{- }} = insert result AND trim whitespace BEFORE
{{  -}} = insert result AND trim whitespace AFTER
{{- -}} = trim both sides

# Why it matters:
{{- if .Values.ingress.enabled }}
# No leading blank line in rendered YAML
{{- end }}

# toYaml + nindent for multiline values:
resources:
  {{- toYaml .Values.resources | nindent 2 }}
# Renders as:
resources:
  requests:
    cpu: 100m
  limits:
    cpu: 500m
```

---

## Q14. How do you handle different Kubernetes API versions in a Helm chart?

```yaml
# Use lookup and capabilities functions
{{- if .Capabilities.APIVersions.Has "networking.k8s.io/v1/Ingress" }}
apiVersion: networking.k8s.io/v1
{{- else }}
apiVersion: extensions/v1beta1
{{- end }}
kind: Ingress

# Specify minimum K8s version
# Chart.yaml
kubeVersion: ">=1.25.0"
```

---

## Q15. A helm upgrade is stuck. What do you do?

```bash
# Check status
helm status my-release -n production
# STATUS: pending-upgrade  ← stuck

# Check what's failing
kubectl get pods -n production
kubectl describe pod failing-pod -n production

# Force-break the stuck state (last resort)
helm upgrade --install my-release ./chart \
  --force \               # Force resource update/delete
  -n production

# Or manually fix the release state
kubectl delete secret sh.helm.release.v1.my-release.vN -n production
# Then re-apply

# If completely broken, uninstall and reinstall
helm uninstall my-release -n production
helm install my-release ./chart -f values.yaml -n production
```
