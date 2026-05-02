# Kustomize Core Concepts

## What is Kustomize?

Kustomize is a **template-free** configuration management tool. Instead of Go templates (like Helm), it applies **strategic merge patches** and **JSON 6902 patches** on top of base Kubernetes YAML.

```
Base YAML + Overlay Patches = Final Manifest
(no {{variables}}, just pure YAML)
```

---

## Key Operations

### 1. Images — Update image tags

```yaml
# kustomization.yaml
images:
- name: myapp                              # Matches image name in deployments
  newName: ghcr.io/myorg/myapp            # New registry
  newTag: abc1234                          # New tag
  # digest: sha256:abc123...              # Pin by digest (more secure)

# In CI/CD:
# kustomize edit set image myapp=ghcr.io/myorg/myapp:$NEW_TAG
```

### 2. Patches — Modify specific fields

```yaml
# Strategic merge patch (merges into base)
patches:
- patch: |-
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: myapp
    spec:
      replicas: 10                        # Override replicas
      template:
        spec:
          containers:
          - name: app
            resources:
              limits:
                memory: "2Gi"
  target:
    kind: Deployment
    name: myapp

# JSON 6902 patch (surgical path-based)
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
        value: "production"
    - op: remove
      path: /spec/template/spec/containers/0/env/0  # Remove first env var
```

### 3. Generators — Create ConfigMaps and Secrets

```yaml
# ConfigMap generator — auto-generates name hash (triggers rolling restart on change)
configMapGenerator:
- name: app-config
  literals:
  - APP_ENV=production
  - LOG_LEVEL=info
  files:
  - app.properties                        # Content of file as value
  envs:
  - .env.production                       # Parse .env file format

# Secret generator
secretGenerator:
- name: db-secrets
  literals:
  - DB_PASSWORD=mypassword               # Don't commit! Use external-secrets
  type: Opaque

# Disable name suffix hash (if you don't want rolling restart)
generatorOptions:
  disableNameSuffixHash: false           # true = no hash suffix
  labels:
    managed-by: kustomize
```

### 4. Common Labels and Annotations

```yaml
# Applied to ALL resources
commonLabels:
  app.kubernetes.io/name: myapp
  app.kubernetes.io/managed-by: kustomize
  environment: production

commonAnnotations:
  contact: platform-team@company.com
  documentation: https://wiki.company.com/myapp
```

### 5. Namespace

```yaml
namespace: production    # Applied to all namespaced resources
```

### 6. Name Prefix/Suffix

```yaml
namePrefix: prod-
nameSuffix: -v2
# Deployment "api" becomes "prod-api-v2"
```

---

## Resource Ordering

```yaml
# resources: list of base files or directories
resources:
- ../../base                    # Another kustomization
- deployment.yaml               # Raw YAML file
- service.yaml
- https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/crds.yaml
- ../cert-manager               # Another kustomization directory
```

---

## Components (Reusable Patches)

```yaml
# components/logging/kustomization.yaml
# (Reusable addon that can be included optionally)
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component

patches:
- patch: |-
    - op: add
      path: /spec/template/spec/containers/0/env/-
      value:
        name: LOG_FORMAT
        value: json
  target:
    kind: Deployment

# Use in overlays:
# components:
# - ../../components/logging
# - ../../components/monitoring
```

---

## CLI Commands

```bash
# Build and preview (no cluster needed)
kustomize build overlays/production/

# Apply directly
kubectl apply -k overlays/production/

# Preview what would be applied
kubectl diff -k overlays/production/

# Edit operations
kustomize edit set image myapp=ghcr.io/myorg/myapp:v1.2.3
kustomize edit set namespace production
kustomize edit add label version:v1
kustomize edit add resource new-resource.yaml

# Validate
kustomize build . | kubectl apply --dry-run=client -f -
kustomize build . | kubeval --strict

# Built into kubectl (since K8s 1.14)
kubectl apply -k .           # Apply
kubectl get -k .             # Get resources
kubectl delete -k .          # Delete resources
kubectl diff -k .            # Diff vs cluster
```
