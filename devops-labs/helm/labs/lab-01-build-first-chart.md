# Lab 01: Build Your First Helm Chart from Scratch

**Difficulty**: Beginner | **Time**: 45 minutes  
**Goal**: Create a production-ready Helm chart for a Flask API, install it, upgrade it, and roll it back.

---

## Part 1: Scaffold the Chart

```bash
# Create cluster
kind create cluster --name helm-lab

# Create the chart skeleton
helm create flask-api
ls flask-api/

# Review what was generated
cat flask-api/Chart.yaml
cat flask-api/values.yaml
ls flask-api/templates/
```

---

## Part 2: Customize Chart.yaml

```bash
cat > flask-api/Chart.yaml << 'EOF'
apiVersion: v2
name: flask-api
description: A production Flask REST API
type: application
version: 0.1.0
appVersion: "1.0.0"
keywords:
  - python
  - flask
  - api
maintainers:
  - name: Platform Team
    email: platform@company.com
EOF
```

---

## Part 3: Set Sensible Defaults in values.yaml

```bash
cat > flask-api/values.yaml << 'EOF'
replicaCount: 2

image:
  repository: nginx           # We'll use nginx as a stand-in
  pullPolicy: IfNotPresent
  tag: ""                     # Defaults to appVersion from Chart.yaml

service:
  type: ClusterIP
  port: 80
  targetPort: 80

ingress:
  enabled: false
  className: nginx
  hosts:
  - host: api.example.com
    paths:
    - path: /
      pathType: Prefix

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi

autoscaling:
  enabled: false
  minReplicas: 2
  maxReplicas: 20
  targetCPUUtilizationPercentage: 70

env:
  APP_ENV: production
  LOG_LEVEL: info

probes:
  liveness:
    path: /healthz
    initialDelaySeconds: 15
  readiness:
    path: /ready
    initialDelaySeconds: 5

podAnnotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "9090"

nodeSelector: {}
tolerations: []
affinity: {}
EOF
```

---

## Part 4: Write the Deployment Template

```bash
cat > flask-api/templates/deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "flask-api.fullname" . }}
  labels:
    {{- include "flask-api.labels" . | nindent 4 }}
spec:
  {{- if not .Values.autoscaling.enabled }}
  replicas: {{ .Values.replicaCount }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "flask-api.selectorLabels" . | nindent 6 }}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
        {{- with .Values.podAnnotations }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      labels:
        {{- include "flask-api.selectorLabels" . | nindent 8 }}
    spec:
      {{- with .Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      containers:
      - name: {{ .Chart.Name }}
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
        imagePullPolicy: {{ .Values.image.pullPolicy }}
        ports:
        - name: http
          containerPort: {{ .Values.service.targetPort }}

        env:
        {{- range $key, $value := .Values.env }}
        - name: {{ $key }}
          value: {{ $value | quote }}
        {{- end }}

        envFrom:
        - configMapRef:
            name: {{ include "flask-api.fullname" . }}-config

        livenessProbe:
          httpGet:
            path: {{ .Values.probes.liveness.path }}
            port: http
          initialDelaySeconds: {{ .Values.probes.liveness.initialDelaySeconds }}
          periodSeconds: 10
          failureThreshold: 3

        readinessProbe:
          httpGet:
            path: {{ .Values.probes.readiness.path }}
            port: http
          initialDelaySeconds: {{ .Values.probes.readiness.initialDelaySeconds }}
          periodSeconds: 5

        resources:
          {{- toYaml .Values.resources | nindent 10 }}

      {{- with .Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
EOF
```

---

## Part 5: Add ConfigMap and HPA Templates

```bash
cat > flask-api/templates/configmap.yaml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "flask-api.fullname" . }}-config
  labels:
    {{- include "flask-api.labels" . | nindent 4 }}
data:
  {{- range $key, $value := .Values.env }}
  {{ $key }}: {{ $value | quote }}
  {{- end }}
EOF

cat > flask-api/templates/hpa.yaml << 'EOF'
{{- if .Values.autoscaling.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "flask-api.fullname" . }}
  labels:
    {{- include "flask-api.labels" . | nindent 4 }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ include "flask-api.fullname" . }}
  minReplicas: {{ .Values.autoscaling.minReplicas }}
  maxReplicas: {{ .Values.autoscaling.maxReplicas }}
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: {{ .Values.autoscaling.targetCPUUtilizationPercentage }}
{{- end }}
EOF
```

---

## Part 6: Lint and Install

```bash
# Lint the chart
helm lint flask-api/
# Should show: 1 chart(s) linted, 0 chart(s) failed

# Preview rendered templates
helm template myapp flask-api/ | head -60

# Dry run (validates against cluster)
helm install myapp flask-api/ --dry-run --debug | head -80

# Install for real
helm install myapp flask-api/ -n default

# Check status
helm status myapp
kubectl get pods,svc -l app.kubernetes.io/instance=myapp

# Access the app
kubectl port-forward svc/myapp-flask-api 8080:80 &
curl http://localhost:8080
```

---

## Part 7: Upgrade and Rollback

```bash
# Upgrade: scale to 5 replicas
helm upgrade myapp flask-api/ --set replicaCount=5
kubectl get pods -l app.kubernetes.io/instance=myapp -w

# Check history
helm history myapp
# REVISION  STATUS    CHART           DESCRIPTION
# 1         superseded flask-api-0.1.0 Install complete
# 2         deployed  flask-api-0.1.0 Upgrade complete

# Rollback to previous version
helm rollback myapp 1
helm history myapp

# Enable HPA with upgrade
helm upgrade myapp flask-api/ \
  --set autoscaling.enabled=true \
  --set autoscaling.minReplicas=3 \
  --set autoscaling.maxReplicas=20

kubectl get hpa
```

---

## Part 8: Package and Share

```bash
# Package the chart into a .tgz
helm package flask-api/
ls *.tgz   # flask-api-0.1.0.tgz

# Inspect a packaged chart
helm show values flask-api-0.1.0.tgz

# Install from .tgz
helm install myapp2 flask-api-0.1.0.tgz

# Cleanup
helm uninstall myapp myapp2
rm flask-api-0.1.0.tgz
kind delete cluster --name helm-lab
```

## What You Learned

- [x] Helm chart scaffold structure
- [x] Go template syntax: `{{ }}`, `{{- }}`, `{{- include }}`, `{{- with }}`
- [x] Installing, upgrading, and rolling back releases
- [x] `helm lint`, `helm template`, `--dry-run` for validation
- [x] HPA as a conditional template with `{{- if }}`
- [x] ConfigMap checksum annotation for rolling restarts
