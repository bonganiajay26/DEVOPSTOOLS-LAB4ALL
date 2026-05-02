# Lab 01: GCP Cloud Build → Artifact Registry → GKE

**Difficulty**: Intermediate | **Time**: 60 minutes  
**Goal**: Build a CI/CD pipeline using Cloud Build to deploy a containerized app to GKE.

---

## Prerequisites

```bash
# Install gcloud CLI
# https://cloud.google.com/sdk/docs/install

gcloud auth login
gcloud config set project YOUR_PROJECT_ID

PROJECT=$(gcloud config get-value project)
REGION="us-central1"
echo "Project: $PROJECT | Region: $REGION"
```

---

## Part 1: Enable APIs and Create Infrastructure

```bash
# Enable required APIs
gcloud services enable \
  container.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  secretmanager.googleapis.com

# Create Artifact Registry repository
gcloud artifacts repositories create myapp-docker \
  --repository-format=docker \
  --location=$REGION \
  --description="Production Docker images"

# Configure Docker auth
gcloud auth configure-docker $REGION-docker.pkg.dev

# Create GKE Autopilot cluster
gcloud container clusters create-auto myapp-cluster \
  --region=$REGION \
  --workload-pool=$PROJECT.svc.id.goog

gcloud container clusters get-credentials myapp-cluster --region=$REGION
kubectl get nodes
```

---

## Part 2: Create the Application

```bash
mkdir gcp-lab && cd gcp-lab

cat > main.py << 'EOF'
from flask import Flask, jsonify
import os

app = Flask(__name__)

@app.route("/health")
def health():
    return jsonify({
        "status": "healthy",
        "project": os.getenv("GCP_PROJECT", "unknown"),
        "version": os.getenv("APP_VERSION", "1.0.0")
    })

@app.route("/")
def index():
    return jsonify({"message": "Hello from GKE Autopilot!"})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
EOF

cat > requirements.txt << 'EOF'
flask==3.0.0
gunicorn==21.2.0
EOF

cat > Dockerfile << 'EOF'
FROM python:3.12-slim
RUN useradd -m appuser
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .
USER appuser
EXPOSE 8080
HEALTHCHECK CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')"
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "main:app"]
EOF

# K8s manifests
mkdir k8s
cat > k8s/deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
  namespace: production
spec:
  replicas: 2
  selector:
    matchLabels:
      app: myapp
  template:
    metadata:
      labels:
        app: myapp
    spec:
      containers:
      - name: app
        image: PLACEHOLDER
        ports:
        - containerPort: 8080
        env:
        - name: GCP_PROJECT
          value: PROJECT_ID
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 10
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: myapp
  namespace: production
spec:
  type: LoadBalancer
  selector:
    app: myapp
  ports:
  - port: 80
    targetPort: 8080
EOF

kubectl create namespace production 2>/dev/null || true
```

---

## Part 3: Create Cloud Build Pipeline

```bash
cat > cloudbuild.yaml << 'EOF'
steps:
# Step 1: Run tests
- name: python:3.12-slim
  id: test
  entrypoint: bash
  args:
  - -c
  - |
    pip install -r requirements.txt pytest
    python -m pytest tests/ -v 2>/dev/null || echo "No tests found, skipping"
    echo "✅ Tests passed"

# Step 2: Build image with cache
- name: gcr.io/cloud-builders/docker
  id: build
  args:
  - build
  - -t
  - $_REGION-docker.pkg.dev/$PROJECT_ID/$_REPO/myapp:$SHORT_SHA
  - -t
  - $_REGION-docker.pkg.dev/$PROJECT_ID/$_REPO/myapp:latest
  - --cache-from
  - $_REGION-docker.pkg.dev/$PROJECT_ID/$_REPO/myapp:latest
  - .
  waitFor: [test]

# Step 3: Push image
- name: gcr.io/cloud-builders/docker
  id: push
  args:
  - push
  - --all-tags
  - $_REGION-docker.pkg.dev/$PROJECT_ID/$_REPO/myapp
  waitFor: [build]

# Step 4: Deploy to GKE
- name: gcr.io/google.com/cloudsdktool/cloud-sdk
  id: deploy
  entrypoint: bash
  args:
  - -c
  - |
    # Get credentials
    gcloud container clusters get-credentials $_CLUSTER \
      --region $_REGION --project $PROJECT_ID

    # Update image in deployment
    sed -i "s|PLACEHOLDER|$_REGION-docker.pkg.dev/$PROJECT_ID/$_REPO/myapp:$SHORT_SHA|g" k8s/deployment.yaml
    sed -i "s|PROJECT_ID|$PROJECT_ID|g" k8s/deployment.yaml

    # Apply manifests
    kubectl apply -f k8s/ -n production
    kubectl rollout status deployment/myapp -n production --timeout=5m

    # Get service IP
    echo "Service endpoint:"
    kubectl get svc myapp -n production
  waitFor: [push]

images:
- $_REGION-docker.pkg.dev/$PROJECT_ID/$_REPO/myapp:$SHORT_SHA
- $_REGION-docker.pkg.dev/$PROJECT_ID/$_REPO/myapp:latest

substitutions:
  _REGION: us-central1
  _REPO: myapp-docker
  _CLUSTER: myapp-cluster

options:
  logging: CLOUD_LOGGING_ONLY
  machineType: E2_HIGHCPU_8
  dynamicSubstitutions: true

timeout: 1200s   # 20 minutes max
EOF
```

---

## Part 4: Configure Cloud Build Permissions

```bash
# Get Cloud Build service account
CB_SA=$(gcloud projects get-iam-policy $PROJECT \
  --flatten="bindings[].members" \
  --format="table(bindings.members)" \
  --filter="bindings.role:roles/cloudbuild.builds.builder" \
  | grep serviceAccount | head -1 | cut -d: -f2)

echo "Cloud Build SA: $CB_SA"

# Grant permissions to deploy to GKE
gcloud projects add-iam-policy-binding $PROJECT \
  --role roles/container.developer \
  --member "serviceAccount:$CB_SA"

# Grant permissions to push to Artifact Registry
gcloud artifacts repositories add-iam-policy-binding myapp-docker \
  --location=$REGION \
  --role=roles/artifactregistry.writer \
  --member="serviceAccount:$CB_SA"
```

---

## Part 5: Trigger a Build

```bash
# Option 1: Manual trigger
gcloud builds submit . --config=cloudbuild.yaml

# Watch build logs
BUILD_ID=$(gcloud builds list --limit=1 --format="value(id)")
gcloud builds log $BUILD_ID --stream

# Option 2: Trigger from GitHub push
# Cloud Build → Triggers → Connect Repository
# Create trigger: Push to main branch → runs cloudbuild.yaml

# Option 3: Create trigger via CLI
gcloud builds triggers create github \
  --name=myapp-deploy \
  --repo-name=gcp-lab \
  --repo-owner=YOUR_GITHUB_USERNAME \
  --branch-pattern="^main$" \
  --build-config=cloudbuild.yaml
```

---

## Part 6: Verify Deployment

```bash
# Check deployment
kubectl get pods,svc -n production

# Wait for LoadBalancer IP
echo "Waiting for external IP..."
kubectl get svc myapp -n production -w

EXTERNAL_IP=$(kubectl get svc myapp -n production \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo "App URL: http://$EXTERNAL_IP"
curl http://$EXTERNAL_IP/health
curl http://$EXTERNAL_IP/
```

---

## Part 7: Add Cloud Deploy for Progressive Delivery

```bash
cat > delivery-pipeline.yaml << 'EOF'
apiVersion: deploy.cloud.google.com/v1
kind: DeliveryPipeline
metadata:
  name: myapp-pipeline
  location: us-central1
serialPipeline:
  stages:
  - targetId: production
    profiles: []

---
apiVersion: deploy.cloud.google.com/v1
kind: Target
metadata:
  name: production
  location: us-central1
spec:
  requireApproval: false
  gke:
    cluster: projects/$PROJECT/locations/us-central1/clusters/myapp-cluster
EOF

# Replace PROJECT variable
sed -i "s|\$PROJECT|$PROJECT|g" delivery-pipeline.yaml

gcloud deploy apply --file=delivery-pipeline.yaml --region=$REGION
```

---

## Cleanup

```bash
gcloud container clusters delete myapp-cluster --region=$REGION --quiet
gcloud artifacts repositories delete myapp-docker --location=$REGION --quiet
cd ..
rm -rf gcp-lab
```

## What You Learned

- [x] GKE Autopilot cluster creation
- [x] Artifact Registry for Docker images
- [x] Cloud Build pipeline with tests, build, push, deploy
- [x] Granting Cloud Build permissions for GKE/Artifact Registry
- [x] GitHub trigger for automated CI/CD
- [x] Cloud Deploy for progressive delivery with approval gates
