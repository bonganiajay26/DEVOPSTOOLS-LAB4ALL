# Lab 02: Docker Build and Deploy Pipeline

**Difficulty**: Intermediate | **Time**: 60 minutes  
**Goal**: Build a complete pipeline that tests code, builds a Docker image, pushes to GHCR, and deploys to a local Kubernetes cluster.

---

## Architecture

```
git push main
     │
     ▼
GitHub Actions
├── 1. Lint (ruff)
├── 2. Test (pytest)
├── 3. Build Docker image (multi-stage)
├── 4. Push to GHCR (GitHub Container Registry)
└── 5. Deploy to kind cluster (local K8s)
```

---

## Part 1: Create a Real Flask API

```bash
mkdir flask-api && cd flask-api
git init

# Application code
cat > app.py << 'EOF'
from flask import Flask, jsonify
import os

app = Flask(__name__)

@app.route("/health")
def health():
    return jsonify({
        "status": "healthy",
        "version": os.getenv("APP_VERSION", "dev"),
        "environment": os.getenv("APP_ENV", "development")
    })

@app.route("/api/v1/items")
def get_items():
    return jsonify({
        "items": [
            {"id": 1, "name": "Widget A", "price": 9.99},
            {"id": 2, "name": "Widget B", "price": 19.99},
        ]
    })

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", 8080)))
EOF

# Tests
mkdir tests && cat > tests/test_app.py << 'EOF'
import pytest
from app import app

@pytest.fixture
def client():
    app.config["TESTING"] = True
    with app.test_client() as c:
        yield c

def test_health(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json["status"] == "healthy"

def test_get_items(client):
    r = client.get("/api/v1/items")
    assert r.status_code == 200
    assert len(r.json["items"]) > 0
EOF

# Requirements
cat > requirements.txt << 'EOF'
flask==3.0.0
gunicorn==21.2.0
EOF

cat > requirements-dev.txt << 'EOF'
-r requirements.txt
pytest==7.4.3
pytest-cov==4.1.0
ruff==0.2.0
EOF
```

### Create the Dockerfile

```dockerfile
# Dockerfile
# Stage 1: Test
FROM python:3.12-slim AS test
WORKDIR /app
COPY requirements-dev.txt .
RUN pip install -r requirements-dev.txt
COPY . .
RUN pytest tests/ -v

# Stage 2: Production
FROM python:3.12-slim AS production
RUN useradd --create-home appuser
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY --chown=appuser:appuser app.py .
USER appuser
EXPOSE 8080
ENV APP_ENV=production
HEALTHCHECK --interval=30s --timeout=5s \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')"
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "app:app"]
```

### Create Kubernetes manifests

```bash
mkdir -p k8s
cat > k8s/deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: flask-api
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: flask-api
  template:
    metadata:
      labels:
        app: flask-api
    spec:
      containers:
      - name: api
        image: ghcr.io/GITHUB_USERNAME/flask-api:IMAGE_TAG
        ports:
        - containerPort: 8080
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
EOF

cat > k8s/service.yaml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: flask-api
spec:
  selector:
    app: flask-api
  ports:
  - port: 80
    targetPort: 8080
  type: ClusterIP
EOF
```

---

## Part 2: Create the Full CI/CD Pipeline

```bash
mkdir -p .github/workflows

cat > .github/workflows/pipeline.yml << 'EOF'
name: CI/CD Pipeline

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}/flask-api

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4
    - uses: actions/setup-python@v5
      with:
        python-version: '3.12'
        cache: pip
    - run: pip install ruff
    - run: ruff check .

  test:
    needs: lint
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4
    - uses: actions/setup-python@v5
      with:
        python-version: '3.12'
        cache: pip
    - run: pip install -r requirements-dev.txt
    - run: pytest tests/ -v --cov=. --cov-report=xml
    - uses: actions/upload-artifact@v4
      with:
        name: test-results
        path: coverage.xml

  build-push:
    needs: test
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    outputs:
      image-tag: ${{ steps.meta.outputs.version }}
      image-digest: ${{ steps.build.outputs.digest }}

    steps:
    - uses: actions/checkout@v4
    - uses: docker/setup-buildx-action@v3
    - uses: docker/login-action@v3
      with:
        registry: ${{ env.REGISTRY }}
        username: ${{ github.actor }}
        password: ${{ secrets.GITHUB_TOKEN }}

    - id: meta
      uses: docker/metadata-action@v5
      with:
        images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
        tags: |
          type=sha,format=short
          type=raw,value=latest

    - id: build
      uses: docker/build-push-action@v5
      with:
        context: .
        target: production
        push: true
        tags: ${{ steps.meta.outputs.tags }}
        cache-from: type=gha
        cache-to: type=gha,mode=max

    - name: Scan image
      uses: aquasecurity/trivy-action@master
      with:
        image-ref: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ steps.meta.outputs.version }}
        severity: CRITICAL
        exit-code: 1

  deploy:
    needs: build-push
    runs-on: ubuntu-latest
    environment:
      name: production
      url: http://localhost:8080   # In real setup: your cluster URL

    steps:
    - uses: actions/checkout@v4

    - name: Update image tag in manifests
      run: |
        IMAGE_TAG=${{ needs.build-push.outputs.image-tag }}
        REGISTRY=${{ env.REGISTRY }}
        IMAGE=${{ env.IMAGE_NAME }}
        sed -i "s|IMAGE_TAG|${IMAGE_TAG}|g" k8s/deployment.yaml
        sed -i "s|GITHUB_USERNAME|${{ github.actor }}|g" k8s/deployment.yaml
        cat k8s/deployment.yaml | grep image:

    - name: Setup kind cluster (for local deploy demo)
      uses: helm/kind-action@v1.9.0
      with:
        cluster_name: demo

    - name: Deploy to kind
      run: |
        # Create imagePullSecret for GHCR
        kubectl create secret docker-registry ghcr-creds \
          --docker-server=ghcr.io \
          --docker-username=${{ github.actor }} \
          --docker-password=${{ secrets.GITHUB_TOKEN }} \
          || true

        kubectl apply -f k8s/
        kubectl rollout status deployment/flask-api --timeout=3m

    - name: Verify deployment
      run: |
        kubectl get pods
        kubectl port-forward svc/flask-api 8080:80 &
        sleep 5
        curl -sf http://localhost:8080/health
        echo "✅ Deployment verified!"
EOF

git add .
git commit -m "ci: add full CI/CD pipeline with Docker and K8s"
git push origin main
```

---

## Part 3: View Pipeline Results

```
GitHub → Actions → CI/CD Pipeline

✅ lint         (15s)
✅ test         (25s)
✅ build-push   (90s)  → pushed to ghcr.io
✅ deploy       (60s)  → deployed to kind cluster
```

### Pull the image locally

```bash
docker pull ghcr.io/YOUR_USERNAME/flask-api/flask-api:latest
docker run -p 8080:8080 ghcr.io/YOUR_USERNAME/flask-api/flask-api:latest
curl http://localhost:8080/health
```

---

## What You Learned

- [x] Multi-stage Docker build (test stage + production stage)
- [x] GHCR authentication via `GITHUB_TOKEN`
- [x] Docker metadata action for smart tagging
- [x] Container security scanning with Trivy
- [x] Job outputs and dependencies
- [x] kind cluster for local K8s deploy in CI
- [x] GitHub Environments for production gates

## Next Lab

→ [Lab 03: Advanced Patterns — Reusable Workflows and Secrets](lab-03-advanced-patterns.md)
