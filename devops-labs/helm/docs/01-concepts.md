# Helm Core Concepts

## What is Helm?

Helm is the **package manager for Kubernetes**. It solves the same problem npm/pip solves for code — distributing, versioning, and installing complex applications.

```
Without Helm:  20 YAML files × 3 environments = 60 files to maintain manually
With Helm:     1 chart + 3 values files = parameterized, versioned, rollback-capable
```

---

## Three Core Concepts

```
1. Chart      — a package of Kubernetes resources (like a deb or rpm package)
2. Release    — a chart installed into a cluster (like an installed application)
3. Repository — a collection of charts (like apt/yum/PyPI)
```

---

## Chart Structure

```
mychart/
├── Chart.yaml          # Metadata: name, version, description, dependencies
├── values.yaml         # Default configuration values
├── values.schema.json  # (Optional) JSON Schema to validate values
├── .helmignore         # Files to exclude when packaging
├── charts/             # Dependency charts (vendored)
├── crds/               # Custom Resource Definitions (installed before templates)
└── templates/
    ├── NOTES.txt       # Post-install instructions printed to user
    ├── _helpers.tpl    # Reusable template snippets (not rendered as resources)
    ├── deployment.yaml
    ├── service.yaml
    ├── ingress.yaml
    ├── configmap.yaml
    ├── hpa.yaml
    ├── serviceaccount.yaml
    └── tests/
        └── test-connection.yaml  # helm test resources
```

---

## The Helm Template Engine

Helm uses **Go templates** to render Kubernetes YAML from parameterized templates.

```yaml
# templates/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "mychart.fullname" . }}      # Function call
  labels:
    {{- include "mychart.labels" . | nindent 4 }} # Included block, indented 4

spec:
  replicas: {{ .Values.replicaCount }}           # Direct value access
  
  {{- if .Values.autoscaling.enabled }}          # Conditional
  # (replicas managed by HPA)
  {{- end }}
  
  template:
    spec:
      containers:
      - name: {{ .Chart.Name }}                  # Chart metadata
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
        
        {{- with .Values.resources }}            # Scoped block
        resources:
          {{- toYaml . | nindent 10 }}           # Convert to YAML, indent
        {{- end }}
        
        {{- range .Values.env }}                 # Loop
        - name: {{ .name }}
          value: {{ .value | quote }}
        {{- end }}
```

---

## Values Hierarchy (precedence: later overrides earlier)

```
1. Chart default values     (values.yaml in the chart)
2. Parent chart values      (if this is a subchart)
3. User-supplied file       (helm install -f myvals.yaml)
4. User-supplied params     (helm install --set key=value)
```

```bash
# Multiple -f files: last file wins for the same key
helm install myapp ./mychart \
  -f values.yaml \          # Base defaults
  -f production.yaml \      # Production overrides
  --set image.tag=abc1234   # Per-deploy override
```

---

## Built-in Objects

```yaml
# Available in every template:
{{ .Release.Name }}         # "myapp"
{{ .Release.Namespace }}    # "production"
{{ .Release.IsInstall }}    # true on first install
{{ .Release.IsUpgrade }}    # true on upgrade
{{ .Release.Revision }}     # 1, 2, 3... (revision number)

{{ .Chart.Name }}           # Chart name from Chart.yaml
{{ .Chart.Version }}        # Chart version
{{ .Chart.AppVersion }}     # App version

{{ .Values.xxx }}           # User-provided values
{{ .Files.Get "config.ini" }} # File content from chart files/

{{ .Capabilities.KubeVersion.Major }}  # K8s major version
{{ .Capabilities.APIVersions.Has "networking.k8s.io/v1/Ingress" }}
```

---

## Template Functions and Pipelines

```yaml
# Functions (Go template style)
{{ quote .Values.someString }}          # Add quotes: "myvalue"
{{ upper .Values.name }}                # Uppercase
{{ default "fallback" .Values.opt }}   # Default value
{{ required "field required!" .Values.must }}  # Error if not set
{{ toYaml .Values.dict | nindent 4 }}  # Dict → YAML, 4-space indent
{{ b64enc .Values.secret }}            # Base64 encode
{{ sha256sum .Values.config }}         # SHA256 hash
{{ randAlphaNum 16 }}                  # Random 16-char string
{{ .Values.name | trunc 63 | trimSuffix "-" }}  # Pipeline

# Common pattern: nindent for multi-line values
env:
  {{- toYaml .Values.extraEnv | nindent 2 }}
```

---

## Hooks

Hooks run at specific points in a release lifecycle:

```yaml
annotations:
  "helm.sh/hook": pre-upgrade          # Run before upgrade
  "helm.sh/hook-weight": "-5"          # Order (-5 runs before 0, before 5)
  "helm.sh/hook-delete-policy": hook-succeeded  # Clean up after success

# Common hooks:
# pre-install    → DB schema creation on first install
# pre-upgrade    → DB migration before new version starts
# post-install   → Send notification, seed data
# test           → Smoke test after deploy (helm test)
```

---

## Subcharts and Global Values

```yaml
# Chart.yaml — declare dependencies
dependencies:
- name: postgresql
  version: "~13.0"
  repository: https://charts.bitnami.com/bitnami
  condition: postgresql.enabled    # Only if true in values

- name: redis
  version: "~18.0"
  repository: https://charts.bitnami.com/bitnami
  alias: cache                     # Rename to 'cache' in values

# values.yaml — configure subcharts
postgresql:
  enabled: true
  auth:
    database: mydb
    username: myuser

cache:                   # Using alias
  enabled: true
  master:
    persistence:
      size: 2Gi

# Global values (shared across all subcharts)
global:
  imageRegistry: "my-private-registry.io"
  imagePullSecrets:
    - name: registry-credentials
```

---

## Helm Chart Testing

```yaml
# templates/tests/test-connection.yaml
apiVersion: v1
kind: Pod
metadata:
  name: "{{ include "mychart.fullname" . }}-test"
  annotations:
    "helm.sh/hook": test            # Only run during helm test
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  restartPolicy: Never
  containers:
  - name: test
    image: curlimages/curl:latest
    command:
    - curl
    - -f
    - "http://{{ include "mychart.fullname" . }}:{{ .Values.service.port }}/health"
```

```bash
helm test myapp -n production
# Runs the test pod, shows PASS/FAIL
```
