# Helm Chart Structure — Production Template

## Directory Layout

```
my-api/
├── Chart.yaml           # Chart metadata (name, version, dependencies)
├── values.yaml          # Default values (override per environment)
├── .helmignore          # Files to exclude from chart packaging
├── charts/              # Dependency charts (vendored)
├── crds/                # Custom Resource Definitions
└── templates/
    ├── _helpers.tpl     # Reusable template snippets
    ├── deployment.yaml
    ├── service.yaml
    ├── ingress.yaml
    ├── configmap.yaml
    ├── secret.yaml
    ├── serviceaccount.yaml
    ├── hpa.yaml
    ├── pdb.yaml
    ├── networkpolicy.yaml
    └── NOTES.txt        # Post-install instructions shown to user
```

---

## Chart.yaml

```yaml
apiVersion: v2
name: my-api
description: Production API service
type: application
version: 1.2.0          # Chart version (change when chart templates change)
appVersion: "2.4.1"     # App version being packaged (cosmetic only)
keywords: [api, backend]
home: https://github.com/myorg/my-api
maintainers:
- name: Platform Team
  email: platform@company.com

dependencies:
- name: postgresql
  version: "~13.0"
  repository: https://charts.bitnami.com/bitnami
  condition: postgresql.enabled    # Only deploy if postgresql.enabled=true
```

---

## values.yaml

```yaml
replicaCount: 3

image:
  repository: ghcr.io/myorg/my-api
  pullPolicy: IfNotPresent
  tag: ""                            # Overridden by CI/CD: --set image.tag=abc1234

imagePullSecrets:
- name: registry-credentials

serviceAccount:
  create: true
  name: ""
  annotations: {}                    # For IRSA: eks.amazonaws.com/role-arn: "arn:..."

service:
  type: ClusterIP
  port: 80
  targetPort: 8080

ingress:
  enabled: false
  className: nginx
  annotations: {}
  hosts:
  - host: api.company.com
    paths:
    - path: /
      pathType: Prefix
  tls:
  - secretName: api-tls
    hosts: [api.company.com]

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi

autoscaling:
  enabled: false
  minReplicas: 3
  maxReplicas: 20
  targetCPUUtilizationPercentage: 70

env:
  APP_ENV: production
  LOG_LEVEL: info

postgresql:
  enabled: false                     # Disable if using external DB

probes:
  liveness:
    path: /health/live
    initialDelaySeconds: 30
  readiness:
    path: /health/ready
    initialDelaySeconds: 10
```

---

## templates/_helpers.tpl

```
{{/*
Expand the name of the chart.
*/}}
{{- define "my-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a fully qualified app name.
*/}}
{{- define "my-api.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Common labels — applied to all resources
*/}}
{{- define "my-api.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "my-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels — used in matchLabels (must be stable, never change)
*/}}
{{- define "my-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "my-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
```

---

## templates/deployment.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "my-api.fullname" . }}
  labels:
    {{- include "my-api.labels" . | nindent 4 }}
spec:
  {{- if not .Values.autoscaling.enabled }}
  replicas: {{ .Values.replicaCount }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "my-api.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
      labels:
        {{- include "my-api.selectorLabels" . | nindent 8 }}
    spec:
      {{- with .Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      serviceAccountName: {{ include "my-api.fullname" . }}
      containers:
      - name: {{ .Chart.Name }}
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
        imagePullPolicy: {{ .Values.image.pullPolicy }}
        ports:
        - containerPort: {{ .Values.service.targetPort }}
        env:
        {{- range $key, $val := .Values.env }}
        - name: {{ $key }}
          value: {{ $val | quote }}
        {{- end }}
        livenessProbe:
          httpGet:
            path: {{ .Values.probes.liveness.path }}
            port: {{ .Values.service.targetPort }}
          initialDelaySeconds: {{ .Values.probes.liveness.initialDelaySeconds }}
        readinessProbe:
          httpGet:
            path: {{ .Values.probes.readiness.path }}
            port: {{ .Values.service.targetPort }}
          initialDelaySeconds: {{ .Values.probes.readiness.initialDelaySeconds }}
        resources:
          {{- toYaml .Values.resources | nindent 10 }}
```

---

## Environment-Specific Values Files

```bash
# prod-values.yaml
replicaCount: 10
image:
  tag: "abc1234"
ingress:
  enabled: true
  hosts:
  - host: api.company.com
autoscaling:
  enabled: true
  minReplicas: 5
  maxReplicas: 50
resources:
  requests:
    cpu: 500m
    memory: 512Mi

# staging-values.yaml
replicaCount: 2
image:
  tag: "def5678"
ingress:
  enabled: true
  hosts:
  - host: staging-api.company.com
autoscaling:
  enabled: false

# Deploy commands:
helm upgrade --install my-api ./my-api \
  -f my-api/values.yaml \
  -f my-api/prod-values.yaml \
  --set image.tag=$(git rev-parse --short HEAD) \
  -n production
```

---

## Helm Hooks

```yaml
# templates/migrate-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "my-api.fullname" . }}-migrate
  annotations:
    "helm.sh/hook": pre-upgrade,pre-install    # Run before install/upgrade
    "helm.sh/hook-weight": "-5"               # Order (lower runs first)
    "helm.sh/hook-delete-policy": hook-succeeded  # Clean up after success
spec:
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: migrate
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        command: ["python", "manage.py", "migrate"]
```

---

## Testing Charts

```bash
# Lint chart syntax
helm lint my-api/

# Render templates locally (no cluster needed)
helm template my-api my-api/ -f my-api/values.yaml

# Dry-run (simulate against cluster)
helm install my-api my-api/ --dry-run --debug

# Test with helm unittest
# tests/deployment_test.yaml:
# suite: Deployment Tests
# templates:
# - deployment.yaml
# tests:
# - it: should have 3 replicas by default
#   asserts:
#   - equal:
#       path: spec.replicas
#       value: 3
```
