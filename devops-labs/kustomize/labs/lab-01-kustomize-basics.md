# Lab 01: Kustomize — Base Overlays and Multi-Environment Deployment

**Difficulty**: Intermediate | **Time**: 45 minutes  
**Goal**: Build a multi-environment Kustomize layout, deploy the same app to dev/staging/production with different configs.

---

## Part 1: Create the Base Application

```bash
mkdir kustomize-lab && cd kustomize-lab
mkdir -p apps/webapp/{base,overlays/{development,staging,production}}

# Base deployment
cat > apps/webapp/base/deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp
spec:
  replicas: 2
  selector:
    matchLabels:
      app: webapp
  template:
    metadata:
      labels:
        app: webapp
    spec:
      containers:
      - name: webapp
        image: nginx:1.25-alpine
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 256Mi
EOF

cat > apps/webapp/base/service.yaml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: webapp
spec:
  selector:
    app: webapp
  ports:
  - port: 80
    targetPort: 80
EOF

cat > apps/webapp/base/configmap.yaml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: webapp-config
data:
  APP_TITLE: "My Web App"
  MAX_UPLOAD_SIZE: "10MB"
  CACHE_TTL: "300"
EOF

# Base kustomization.yaml
cat > apps/webapp/base/kustomization.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- deployment.yaml
- service.yaml
- configmap.yaml

commonLabels:
  app.kubernetes.io/name: webapp
  app.kubernetes.io/component: frontend

commonAnnotations:
  team: web-team
EOF

# Preview the base
kustomize build apps/webapp/base/
echo "=== Base build successful ==="
```

---

## Part 2: Development Overlay

```bash
cat > apps/webapp/overlays/development/kustomization.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- ../../base

namespace: development

# Override image to use dev build
images:
- name: nginx
  newTag: 1.24-alpine    # Pin older version for dev testing

# Override config for dev
configMapGenerator:
- name: webapp-config
  behavior: merge
  literals:
  - APP_TITLE=My Web App (DEV)
  - CACHE_TTL=0           # Disable caching in dev
  - DEBUG=true

# Reduce replicas in dev
patches:
- patch: |-
    - op: replace
      path: /spec/replicas
      value: 1
  target:
    kind: Deployment
    name: webapp
EOF

# Build and verify
kustomize build apps/webapp/overlays/development/ | grep -E "replicas:|namespace:|APP_TITLE"
```

---

## Part 3: Staging Overlay

```bash
cat > apps/webapp/overlays/staging/kustomization.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- ../../base

namespace: staging

images:
- name: nginx
  newTag: 1.25-alpine

configMapGenerator:
- name: webapp-config
  behavior: merge
  literals:
  - APP_TITLE=My Web App (STAGING)
  - CACHE_TTL=60

patches:
- patch: |-
    - op: replace
      path: /spec/replicas
      value: 2
  target:
    kind: Deployment
    name: webapp
- patch: |-
    - op: replace
      path: /spec/template/spec/containers/0/resources/limits/memory
      value: 512Mi
  target:
    kind: Deployment
    name: webapp
EOF
```

---

## Part 4: Production Overlay

```bash
cat > apps/webapp/overlays/production/kustomization.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- ../../base

namespace: production

images:
- name: nginx
  newName: ghcr.io/myorg/webapp
  newTag: v1.2.3          # Will be updated by CI

namePrefix: prod-         # All resources get "prod-" prefix

configMapGenerator:
- name: webapp-config
  behavior: merge
  literals:
  - APP_TITLE=My Web App
  - MAX_UPLOAD_SIZE=50MB
  - CACHE_TTL=3600

patches:
- patch: |-
    - op: replace
      path: /spec/replicas
      value: 5
  target:
    kind: Deployment
    name: webapp

- patch: |-
    - op: replace
      path: /spec/template/spec/containers/0/resources/requests/cpu
      value: "200m"
    - op: replace
      path: /spec/template/spec/containers/0/resources/requests/memory
      value: "256Mi"
    - op: replace
      path: /spec/template/spec/containers/0/resources/limits/cpu
      value: "1000m"
    - op: replace
      path: /spec/template/spec/containers/0/resources/limits/memory
      value: "1Gi"
  target:
    kind: Deployment
    name: webapp
EOF
```

---

## Part 5: Deploy and Compare

```bash
# Create local cluster
kind create cluster --name kustomize-lab

# Create namespaces
kubectl create namespace development
kubectl create namespace staging
kubectl create namespace production

# Deploy all three environments
kubectl apply -k apps/webapp/overlays/development/
kubectl apply -k apps/webapp/overlays/staging/
kubectl apply -k apps/webapp/overlays/production/

# Compare: replicas across environments
echo "=== Replicas per environment ==="
for ns in development staging production; do
    REPLICAS=$(kubectl get deployment -n $ns -o jsonpath='{.items[0].spec.replicas}' 2>/dev/null)
    echo "$ns: $REPLICAS replicas"
done

# Compare: config values
echo ""
echo "=== APP_TITLE per environment ==="
for ns in development staging production; do
    TITLE=$(kubectl get configmap -n $ns -o jsonpath='{.items[0].data.APP_TITLE}' 2>/dev/null)
    echo "$ns: $TITLE"
done

# Diff: what changes between staging and production?
echo ""
echo "=== Diff: staging vs production ==="
diff <(kustomize build apps/webapp/overlays/staging/) \
     <(kustomize build apps/webapp/overlays/production/) || true
```

---

## Part 6: CI/CD Image Update Pattern

```bash
# Simulate what CI/CD does: update image tag after successful build

NEW_TAG="abc1234"

cd apps/webapp/overlays/production

# Update image tag
kustomize edit set image ghcr.io/myorg/webapp=ghcr.io/myorg/webapp:$NEW_TAG

# Verify change
grep "newTag" kustomization.yaml

# In real GitOps:
# git add kustomization.yaml
# git commit -m "deploy: update webapp to $NEW_TAG"
# git push
# ArgoCD detects change and syncs

cd ../../../..

# Apply updated production
kubectl apply -k apps/webapp/overlays/production/
kubectl rollout status deployment/prod-webapp -n production
```

---

## Cleanup

```bash
kind delete cluster --name kustomize-lab
cd ..
rm -rf kustomize-lab
```

## What You Learned

- [x] Base + overlay directory structure
- [x] Strategic merge patches for resource modification
- [x] JSON 6902 patches for precise field changes
- [x] ConfigMap generators with environment overrides
- [x] Image management with `kustomize edit set image`
- [x] Name prefix/suffix for environment separation
- [x] Diffing overlays to see environment differences
