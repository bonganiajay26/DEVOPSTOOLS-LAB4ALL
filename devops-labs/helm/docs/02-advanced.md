# Helm Advanced Patterns

## 1. Library Charts (Shared Template Logic)

```yaml
# Library chart: shared helpers across multiple charts
# Chart.yaml
apiVersion: v2
name: common-library
type: library        # ← Key: library charts can't be installed directly

# templates/_deployment.tpl  (in library chart)
{{- define "common.deployment" -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "common.fullname" . }}
  labels: {{- include "common.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount | default 2 }}
  selector:
    matchLabels: {{- include "common.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels: {{- include "common.selectorLabels" . | nindent 8 }}
    spec:
      containers:
      - name: {{ .Chart.Name }}
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        {{- with .Values.resources }}
        resources: {{- toYaml . | nindent 10 }}
        {{- end }}
{{- end }}

# In an application chart:
# Chart.yaml
dependencies:
- name: common-library
  version: "1.0.0"
  repository: "oci://ghcr.io/myorg/charts"

# templates/deployment.yaml (just one line!)
{{ include "common.deployment" . }}
```

---

## 2. Post-Renderer — Kustomize as a Post-Processor

```bash
# Apply Kustomize patches AFTER Helm renders templates
# Useful: add annotations Helm chart doesn't expose as values

cat > kustomize.sh << 'EOF'
#!/bin/bash
cat <&0 > /tmp/helm-output.yaml
kubectl kustomize /tmp/kustomize-patch >> /tmp/helm-output.yaml
cat /tmp/helm-output.yaml
EOF
chmod +x kustomize.sh

helm install myapp ./mychart --post-renderer ./kustomize.sh
```

---

## 3. Helm Secrets Plugin (SOPS Integration)

```bash
# Install
helm plugin install https://github.com/jkroepke/helm-secrets

# Encrypt secrets.yaml with SOPS (uses AWS KMS or age key)
helm secrets encrypt secrets.yaml

# Install using encrypted secrets
helm secrets install myapp ./mychart \
  -f values.yaml \
  -f secrets://secrets.enc.yaml   # Decrypted on-the-fly

# In CI/CD (age key from env):
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
helm secrets upgrade --install myapp ./mychart -f secrets://secrets.enc.yaml
```

---

## 4. Helmfile — Declarative Multi-Chart Management

```yaml
# helmfile.yaml — manage many releases declaratively
repositories:
- name: prometheus-community
  url: https://prometheus-community.github.io/helm-charts
- name: bitnami
  url: https://charts.bitnami.com/bitnami

environments:
  staging:
    values:
    - environments/staging.yaml
  production:
    values:
    - environments/production.yaml

releases:
- name: monitoring
  namespace: monitoring
  chart: prometheus-community/kube-prometheus-stack
  version: "58.0.0"
  values:
  - monitoring/values.yaml
  - monitoring/values.{{ .Environment.Name }}.yaml  # env-specific

- name: myapp
  namespace: production
  chart: ./charts/myapp
  version: "1.2.0"
  values:
  - myapp/values.yaml
  needs:                    # Deploy after monitoring is ready
  - monitoring/monitoring
```

```bash
helmfile sync                          # Deploy/update all releases
helmfile diff                          # Preview changes
helmfile apply --environment staging   # Deploy to specific env
helmfile destroy                       # Remove all releases
```

---

## 5. OCI Registry for Chart Distribution

```bash
# Push chart to OCI registry (GHCR, ECR, etc.)
helm package ./mychart
helm push mychart-1.0.0.tgz oci://ghcr.io/myorg/charts

# Install from OCI
helm install myapp oci://ghcr.io/myorg/charts/mychart --version 1.0.0

# Pull and inspect
helm pull oci://ghcr.io/myorg/charts/mychart --version 1.0.0 --untar

# List tags
helm show chart oci://ghcr.io/myorg/charts/mychart --version 1.0.0
```

---

## 6. Schema Validation

```json
// values.schema.json — validates user-provided values
{
  "$schema": "http://json-schema.org/schema#",
  "type": "object",
  "required": ["image"],
  "properties": {
    "replicaCount": {
      "type": "integer",
      "minimum": 1,
      "maximum": 100
    },
    "image": {
      "type": "object",
      "required": ["repository", "tag"],
      "properties": {
        "repository": { "type": "string" },
        "tag": { "type": "string" },
        "pullPolicy": {
          "type": "string",
          "enum": ["Always", "Never", "IfNotPresent"]
        }
      }
    },
    "resources": {
      "type": "object",
      "properties": {
        "limits": { "type": "object" },
        "requests": { "type": "object" }
      }
    }
  }
}
```

---

## 7. Helm Unittest

```yaml
# tests/deployment_test.yaml
suite: Deployment Tests
templates:
- templates/deployment.yaml
tests:
- it: should have default replica count of 2
  asserts:
  - equal:
      path: spec.replicas
      value: 2

- it: should use image tag from values
  set:
    image.tag: v1.2.3
  asserts:
  - matchRegex:
      path: spec.template.spec.containers[0].image
      pattern: ":v1.2.3$"

- it: should not create HPA when autoscaling disabled
  set:
    autoscaling.enabled: false
  templates:
  - templates/hpa.yaml
  asserts:
  - hasDocuments:
      count: 0

- it: should fail when replicas > 100
  set:
    replicaCount: 150
  asserts:
  - failedTemplate:
      errorMessage: "replicaCount must be <= 100"
```

```bash
helm plugin install https://github.com/helm-unittest/helm-unittest
helm unittest ./mychart
```

---

## 8. Helm Diff Plugin

```bash
helm plugin install https://github.com/databus23/helm-diff

# See exactly what will change before upgrading
helm diff upgrade myapp ./mychart -f values.yaml

# Output:
# default, myapp, Deployment (apps) has changed:
#   spec:
#     template:
#       spec:
#         containers:
#           - image: myapp:v1.2.2 → myapp:v1.2.3

# Compare two revisions
helm diff revision myapp 2 3
```
