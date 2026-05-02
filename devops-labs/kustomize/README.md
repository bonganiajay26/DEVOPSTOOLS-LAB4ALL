# Kustomize

> **Declarative K8s configuration management. Overlay base manifests per environment — no templates.**

---

## Core Concept

```
Base (common YAML) + Overlay (environment differences) = Final Manifest

No templating language. Pure YAML + patches.
```

---

## Quick Start

```bash
# Install
kubectl kustomize --version  # Built into kubectl since 1.14

# Standalone
curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash

# Build and apply
kubectl apply -k overlays/production/
kustomize build overlays/production/ | kubectl apply -f -

# Preview
kustomize build overlays/production/
```

---

## Directory Structure

```
my-app/
├── base/
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   └── configmap.yaml
└── overlays/
    ├── development/
    │   ├── kustomization.yaml      # 1 replica, debug logging, dev image
    │   └── patches/
    │       └── replica-patch.yaml
    ├── staging/
    │   ├── kustomization.yaml
    │   └── patches/
    └── production/
        ├── kustomization.yaml      # 10 replicas, prod image, HPA enabled
        └── patches/
```

---

## base/kustomization.yaml

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- deployment.yaml
- service.yaml
- configmap.yaml

# Common labels added to all resources
commonLabels:
  app: my-api
  managed-by: kustomize

# Common annotations
commonAnnotations:
  team: platform
```

---

## overlays/production/kustomization.yaml

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- ../../base           # Include base

# Update image tag
images:
- name: myapp
  newName: ghcr.io/myorg/myapp
  newTag: abc1234      # Set by CI: kustomize edit set image myapp=...

# Strategic merge patch — merge changes into base YAML
patches:
- path: patches/deployment-patch.yaml
  target:
    kind: Deployment
    name: my-api

# JSON6902 patch — precise path-based updates
- target:
    kind: Deployment
    name: my-api
  patch: |-
    - op: replace
      path: /spec/replicas
      value: 10

# Add extra resources only in production
- path: hpa.yaml
- path: pdb.yaml

# Name prefix/suffix per environment
nameSuffix: -production
# namePrefix: prod-

# Namespace
namespace: production

# Config generators
configMapGenerator:
- name: app-config
  behavior: merge         # merge with base configmap
  literals:
  - APP_ENV=production
  - LOG_LEVEL=info
  - REPLICA_COUNT=10
```

---

## patches/deployment-patch.yaml (Strategic Merge)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-api               # Must match base resource name
spec:
  replicas: 10
  template:
    spec:
      containers:
      - name: app            # Must match container name in base
        resources:
          requests:
            cpu: "500m"
            memory: "512Mi"
          limits:
            cpu: "2000m"
            memory: "2Gi"
        env:
        - name: FEATURE_X_ENABLED
          value: "true"
```

---

## Interview Questions

**Q: Kustomize vs Helm?**
- Kustomize: patches existing YAML, no templating, simpler
- Helm: full templating, versioning, dependency management
- Use both: Helm for third-party tools, Kustomize for your apps

**Q: How do you update image tag in GitOps pipeline?**
```bash
cd overlays/production
kustomize edit set image myapp=ghcr.io/myorg/myapp:$NEW_TAG
git commit -am "chore: deploy myapp $NEW_TAG"
git push  # ArgoCD/Flux picks up change
```

**Q: How do you handle namespace differences between environments?**
```yaml
# overlays/staging/kustomization.yaml
namespace: staging
# Kustomize applies this namespace to all resources in the overlay
```
