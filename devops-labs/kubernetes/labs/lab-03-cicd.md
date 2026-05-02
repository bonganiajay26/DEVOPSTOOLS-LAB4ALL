# Lab 03: CI/CD Pipeline — GitHub Actions → Docker → Kubernetes

**Difficulty**: Intermediate | **Time**: 45 minutes  
**Goal**: Build a complete pipeline: code push → test → build image → push to registry → deploy to Kubernetes.

---

## Pipeline Overview

```
git push main
     │
     ▼
GitHub Actions
├── 1. Run unit tests
├── 2. Build Docker image
├── 3. Push to GitHub Container Registry (GHCR)
├── 4. Update K8s deployment image tag
└── 5. Verify rollout

Total time: ~3-5 minutes
```

---

## Part 1: Sample Application

### Directory structure

```
my-api/
├── src/
│   └── app.py
├── tests/
│   └── test_app.py
├── Dockerfile
├── .github/
│   └── workflows/
│       └── deploy.yml
└── k8s/
    ├── deployment.yaml
    └── service.yaml
```

### app.py

```python
# src/app.py
from flask import Flask, jsonify
import os

app = Flask(__name__)

@app.route("/health")
def health():
    return jsonify({"status": "healthy", "version": os.getenv("APP_VERSION", "unknown")})

@app.route("/")
def home():
    return jsonify({"message": "Hello from K8s!", "env": os.getenv("APP_ENV", "dev")})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", 8080)))
```

### test_app.py

```python
# tests/test_app.py
import pytest
from src.app import app

@pytest.fixture
def client():
    app.config["TESTING"] = True
    with app.test_client() as c:
        yield c

def test_health(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json["status"] == "healthy"

def test_home(client):
    r = client.get("/")
    assert r.status_code == 200
    assert "message" in r.json
```

### Dockerfile (multi-stage)

```dockerfile
# Dockerfile
# Stage 1: Test
FROM python:3.12-slim AS test
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt pytest
COPY . .
RUN pytest tests/ -v

# Stage 2: Build production image
FROM python:3.12-slim AS production
WORKDIR /app
# Create non-root user
RUN useradd --create-home appuser
USER appuser
# Install dependencies
COPY --chown=appuser:appuser requirements.txt .
RUN pip install --user -r requirements.txt
# Copy app
COPY --chown=appuser:appuser src/ ./src/
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')"
CMD ["python", "src/app.py"]
```

---

## Part 2: Kubernetes Manifests

### k8s/deployment.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-api
  namespace: production
  labels:
    app: my-api
spec:
  replicas: 3
  selector:
    matchLabels:
      app: my-api
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: my-api
    spec:
      containers:
      - name: api
        # IMAGE_TAG is replaced by the CI pipeline
        image: ghcr.io/GITHUB_USERNAME/my-api:IMAGE_TAG
        ports:
        - containerPort: 8080
        env:
        - name: APP_ENV
          value: production
        - name: APP_VERSION
          value: "IMAGE_TAG"
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 5
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "500m"
            memory: "256Mi"
```

### k8s/service.yaml

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-api
  namespace: production
spec:
  selector:
    app: my-api
  ports:
  - port: 80
    targetPort: 8080
```

---

## Part 3: GitHub Actions Workflow

### .github/workflows/deploy.yml

```yaml
name: Build, Test, and Deploy

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}/my-api

jobs:
  # ── Job 1: Test ──────────────────────────────────────────
  test:
    name: Run Tests
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4

    - name: Set up Python
      uses: actions/setup-python@v5
      with:
        python-version: "3.12"
        cache: pip

    - name: Install dependencies
      run: pip install -r requirements.txt pytest pytest-cov

    - name: Run tests with coverage
      run: pytest tests/ -v --cov=src --cov-report=xml

    - name: Upload coverage
      uses: codecov/codecov-action@v4
      with:
        file: coverage.xml

  # ── Job 2: Build & Push ──────────────────────────────────
  build:
    name: Build and Push Image
    needs: test                        # Only run if tests pass
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main'  # Only on main branch
    permissions:
      contents: read
      packages: write                  # Needed to push to GHCR
    outputs:
      image-tag: ${{ steps.meta.outputs.version }}
      image-digest: ${{ steps.build.outputs.digest }}

    steps:
    - uses: actions/checkout@v4

    - name: Set up Docker Buildx
      uses: docker/setup-buildx-action@v3

    - name: Log in to GHCR
      uses: docker/login-action@v3
      with:
        registry: ${{ env.REGISTRY }}
        username: ${{ github.actor }}
        password: ${{ secrets.GITHUB_TOKEN }}  # Auto-generated, no setup needed

    - name: Extract metadata
      id: meta
      uses: docker/metadata-action@v5
      with:
        images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
        tags: |
          type=sha,prefix=,format=short    # Short commit SHA: abc1234
          type=raw,value=latest,enable={{is_default_branch}}

    - name: Build and push
      id: build
      uses: docker/build-push-action@v5
      with:
        context: .
        push: true
        tags: ${{ steps.meta.outputs.tags }}
        labels: ${{ steps.meta.outputs.labels }}
        cache-from: type=gha           # GitHub Actions cache
        cache-to: type=gha,mode=max
        # Build only production stage (skips test stage)
        target: production

    - name: Image digest
      run: echo "Pushed image digest ${{ steps.build.outputs.digest }}"

  # ── Job 3: Deploy ────────────────────────────────────────
  deploy:
    name: Deploy to Kubernetes
    needs: build
    runs-on: ubuntu-latest
    environment:
      name: production
      url: https://api.mycompany.com   # Shows in GitHub Environments tab

    steps:
    - uses: actions/checkout@v4

    - name: Set up kubectl
      uses: azure/setup-kubectl@v4
      with:
        version: "v1.29.0"

    - name: Configure kubeconfig
      run: |
        mkdir -p $HOME/.kube
        echo "${{ secrets.KUBECONFIG }}" | base64 -d > $HOME/.kube/config
        chmod 600 $HOME/.kube/config

    - name: Update image tag in manifest
      run: |
        IMAGE_TAG=${{ needs.build.outputs.image-tag }}
        sed -i "s|IMAGE_TAG|${IMAGE_TAG}|g" k8s/deployment.yaml
        echo "Deploying image tag: ${IMAGE_TAG}"
        cat k8s/deployment.yaml | grep image:

    - name: Apply manifests
      run: |
        kubectl apply -f k8s/
        kubectl rollout status deployment/my-api -n production --timeout=5m

    - name: Verify deployment
      run: |
        kubectl get pods -n production -l app=my-api
        # Check all pods are running the new image
        kubectl get deployment my-api -n production -o jsonpath='{.spec.template.spec.containers[0].image}'

    - name: Smoke test
      run: |
        # Port-forward and hit the health endpoint
        kubectl port-forward svc/my-api 8080:80 -n production &
        sleep 5
        HEALTH=$(curl -sf http://localhost:8080/health | jq -r .status)
        if [ "$HEALTH" != "healthy" ]; then
          echo "Smoke test FAILED"
          kubectl rollout undo deployment/my-api -n production
          exit 1
        fi
        echo "Smoke test PASSED"

    - name: Notify on failure
      if: failure()
      uses: slackapi/slack-github-action@v1.26.0
      with:
        channel-id: "C0DEPLOYALERTS"
        slack-message: "❌ Deployment of `my-api` FAILED on commit ${{ github.sha }}"
      env:
        SLACK_BOT_TOKEN: ${{ secrets.SLACK_BOT_TOKEN }}
```

---

## Part 4: GitHub Secrets to Configure

Go to: **Settings → Secrets and variables → Actions → New repository secret**

| Secret Name | Value |
|-------------|-------|
| `KUBECONFIG` | `cat ~/.kube/config \| base64` |
| `SLACK_BOT_TOKEN` | Slack bot OAuth token |

---

## Part 5: Test the Pipeline

```bash
# Make a change
echo "# Updated" >> README.md

# Commit and push
git add .
git commit -m "test: trigger CI/CD pipeline"
git push origin main

# Watch at: github.com/<your-org>/<repo>/actions
```

### Expected pipeline output:
```
✅ test         (30s)  — pytest passes
✅ build        (90s)  — image pushed to GHCR
✅ deploy       (60s)  — rollout complete, smoke test passed
```

---

## What You Learned

- [x] Multi-stage Dockerfile with test + production stages
- [x] GitHub Actions with job dependencies
- [x] GHCR image publishing with GITHUB_TOKEN
- [x] `sed` for dynamic image tag injection
- [x] Smoke testing post-deployment
- [x] Automatic rollback on smoke test failure

## Next Lab

→ [Lab 04: Full Observability with Prometheus & Grafana](lab-04-observability.md)
