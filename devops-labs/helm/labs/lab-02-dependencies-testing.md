# Lab 02: Helm Dependencies, Testing & Publishing

**Difficulty**: Intermediate | **Time**: 60 minutes  
**Goal**: Add chart dependencies (PostgreSQL, Redis), write helm tests, and publish to GHCR.

---

## Part 1: Add Dependencies

```bash
kind create cluster --name helm-deps-lab

# Update Chart.yaml to add dependencies
cat >> flask-api/Chart.yaml << 'EOF'

dependencies:
- name: postgresql
  version: "~13.4"
  repository: https://charts.bitnami.com/bitnami
  condition: postgresql.enabled

- name: redis
  version: "~18.0"
  repository: https://charts.bitnami.com/bitnami
  condition: redis.enabled
  alias: cache
EOF

# Download dependencies
helm dependency update flask-api/
ls flask-api/charts/      # postgresql-13.x.x.tgz, redis-18.x.x.tgz
cat flask-api/Chart.lock  # Pinned dependency versions
```

---

## Part 2: Configure Subchart Values

```bash
cat >> flask-api/values.yaml << 'EOF'

# PostgreSQL dependency configuration
postgresql:
  enabled: true
  auth:
    database: appdb
    username: appuser
    password: ""           # Will be auto-generated
  primary:
    persistence:
      enabled: true
      size: 5Gi

# Redis dependency configuration (using alias 'cache')
cache:
  enabled: false           # Disable by default, enable per environment
  master:
    persistence:
      enabled: false
EOF
```

---

## Part 3: Write Helm Tests

```bash
mkdir -p flask-api/templates/tests

cat > flask-api/templates/tests/test-connection.yaml << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: "{{ include "flask-api.fullname" . }}-test-conn"
  labels:
    {{- include "flask-api.labels" . | nindent 4 }}
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  restartPolicy: Never
  containers:
  - name: test-http
    image: curlimages/curl:latest
    command:
    - sh
    - -c
    - |
      set -e
      echo "Testing HTTP endpoint..."
      curl -sf "http://{{ include "flask-api.fullname" . }}:{{ .Values.service.port }}/"
      echo "✅ HTTP test passed"
      
      {{- if .Values.postgresql.enabled }}
      echo "Testing database connectivity..."
      # Using nc to test TCP connection
      nc -z {{ include "flask-api.fullname" . }}-postgresql 5432
      echo "✅ Database connectivity test passed"
      {{- end }}
      
      echo "All tests passed!"
EOF

cat > flask-api/templates/tests/test-metrics.yaml << 'EOF'
{{- if .Values.podAnnotations }}
{{- if index .Values.podAnnotations "prometheus.io/scrape" }}
apiVersion: v1
kind: Pod
metadata:
  name: "{{ include "flask-api.fullname" . }}-test-metrics"
  annotations:
    "helm.sh/hook": test
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  restartPolicy: Never
  containers:
  - name: test-metrics
    image: curlimages/curl:latest
    command:
    - sh
    - -c
    - |
      METRICS_PORT={{ index .Values.podAnnotations "prometheus.io/port" | default "8080" }}
      curl -sf "http://{{ include "flask-api.fullname" . }}:$METRICS_PORT/metrics" | \
        grep -q "# HELP" && echo "✅ Metrics endpoint OK" || exit 1
{{- end }}
{{- end }}
EOF
```

---

## Part 4: Install with Dependencies

```bash
# Install with PostgreSQL enabled
helm install myapp flask-api/ \
  --set postgresql.enabled=true \
  --set postgresql.auth.password=devpassword \
  -n default \
  --wait \
  --timeout 3m

# Check all pods
kubectl get pods
# myapp-flask-api-xxxx           1/1 Running
# myapp-postgresql-0             1/1 Running

# Check services
kubectl get svc
# myapp-flask-api     ClusterIP
# myapp-postgresql    ClusterIP

# Run tests
helm test myapp
# NAME: myapp-flask-api-test-conn
# STATUS: passed
```

---

## Part 5: Schema Validation

```bash
cat > flask-api/values.schema.json << 'EOF'
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "properties": {
    "replicaCount": {
      "type": "integer",
      "minimum": 1,
      "maximum": 50,
      "description": "Number of replicas"
    },
    "image": {
      "type": "object",
      "required": ["repository"],
      "properties": {
        "repository": { "type": "string" },
        "tag":        { "type": "string" },
        "pullPolicy": {
          "type": "string",
          "enum": ["Always", "Never", "IfNotPresent"]
        }
      }
    },
    "resources": {
      "type": "object",
      "properties": {
        "limits":   { "type": "object" },
        "requests": { "type": "object" }
      }
    }
  }
}
EOF

# Test schema validation
helm install test flask-api/ --set replicaCount=100 --dry-run
# Error: replicaCount must be <= 50

helm install test flask-api/ --set replicaCount=5 --dry-run
# Works fine
```

---

## Part 6: Publish Chart to OCI Registry

```bash
# Package the chart
helm package flask-api/ --version 1.0.0
ls flask-api-1.0.0.tgz

# Login to GHCR
echo $GITHUB_TOKEN | helm registry login ghcr.io \
  --username $GITHUB_USERNAME \
  --password-stdin

# Push to GHCR
helm push flask-api-1.0.0.tgz oci://ghcr.io/$GITHUB_USERNAME/charts

# Pull and install from registry
helm install myapp oci://ghcr.io/$GITHUB_USERNAME/charts/flask-api \
  --version 1.0.0 \
  --set postgresql.auth.password=devpassword

# Show chart info
helm show chart oci://ghcr.io/$GITHUB_USERNAME/charts/flask-api --version 1.0.0
helm show values oci://ghcr.io/$GITHUB_USERNAME/charts/flask-api --version 1.0.0

# Helm chart release automation (GitHub Actions):
# .github/workflows/helm-release.yml
# on: push (tags: v*)
# steps:
#   helm package ./flask-api --version ${VERSION}
#   helm push flask-api-${VERSION}.tgz oci://ghcr.io/myorg/charts
```

---

## Cleanup

```bash
helm uninstall myapp
kind delete cluster --name helm-deps-lab
rm flask-api-1.0.0.tgz
```

## What You Learned

- [x] Chart dependencies with conditions and aliases
- [x] `helm dependency update` to download dependencies
- [x] Writing and running `helm test` pods
- [x] JSON schema validation for values
- [x] Publishing charts to OCI registries (GHCR)
