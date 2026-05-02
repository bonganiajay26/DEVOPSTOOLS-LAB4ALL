# GCP DevOps Core Services

## Platform Overview

```
┌─────────────────────────────────────────────────────────────┐
│                   GCP DevOps Ecosystem                      │
│                                                             │
│  CI/CD Pipeline:                                            │
│  Cloud Source Repos / GitHub → Cloud Build → GKE           │
│                                                             │
│  Container Services:                                        │
│  Artifact Registry → GKE (Standard) / GKE (Autopilot)     │
│                      Cloud Run (serverless containers)      │
│                                                             │
│  Infrastructure:                                            │
│  Cloud Deployment Manager / Config Connector / Terraform    │
│                                                             │
│  Observability:                                             │
│  Cloud Monitoring + Cloud Logging + Cloud Trace             │
│                                                             │
│  Secrets & Config:                                          │
│  Secret Manager + Cloud Key Management (KMS)               │
│                                                             │
│  Identity:                                                  │
│  Cloud IAM + Workload Identity Federation                   │
└─────────────────────────────────────────────────────────────┘
```

---

## Core Services Comparison

| GCP Service | AWS Equivalent | Azure Equivalent |
|-------------|---------------|-----------------|
| GKE | EKS | AKS |
| Cloud Build | CodeBuild | Azure Pipelines |
| Cloud Deploy | CodeDeploy | Azure Pipelines Environments |
| Artifact Registry | ECR | ACR |
| Cloud Run | Fargate | Container Apps |
| Secret Manager | Secrets Manager | Key Vault |
| Cloud Monitoring | CloudWatch | Azure Monitor |
| Cloud Logging | CloudWatch Logs | Log Analytics |
| IAM | IAM | Azure AD |
| Workload Identity | IRSA | Workload Identity |
| Cloud Source Repos | CodeCommit | Azure Repos |

---

## GKE — Google Kubernetes Engine

```bash
# Autopilot mode (recommended for most workloads)
gcloud container clusters create-auto my-cluster \
  --region us-central1

# Standard mode (when you need full control)
gcloud container clusters create my-cluster \
  --region us-central1 \
  --machine-type n2-standard-4 \
  --num-nodes 3 \
  --enable-autoscaling --min-nodes 1 --max-nodes 10 \
  --enable-ip-alias \
  --workload-pool=$(gcloud config get-value project).svc.id.goog

# Get credentials
gcloud container clusters get-credentials my-cluster --region us-central1

# Upgrade cluster
gcloud container clusters upgrade my-cluster \
  --master --cluster-version 1.29 \
  --region us-central1
```

### GKE Node Auto-Provisioning (NAP)

```bash
# Enable Node Auto-Provisioning — creates node pools automatically
gcloud container clusters update my-cluster \
  --enable-autoprovisioning \
  --max-cpu 100 \
  --max-memory 256 \
  --region us-central1
```

---

## Artifact Registry

```bash
PROJECT=$(gcloud config get-value project)
REGION="us-central1"

# Create Docker repository
gcloud artifacts repositories create my-docker-repo \
  --repository-format=docker \
  --location=$REGION \
  --description="Docker images for production"

# Login
gcloud auth configure-docker $REGION-docker.pkg.dev

# Push image
docker tag myapp:latest $REGION-docker.pkg.dev/$PROJECT/my-docker-repo/myapp:latest
docker push $REGION-docker.pkg.dev/$PROJECT/my-docker-repo/myapp:latest

# Scan for vulnerabilities (built-in)
gcloud artifacts docker images scan $REGION-docker.pkg.dev/$PROJECT/my-docker-repo/myapp:latest

# Cleanup policy (delete images older than 30 days)
gcloud artifacts repositories set-cleanup-policies my-docker-repo \
  --location=$REGION \
  --policy='[{"name":"delete-old","action":"Delete","condition":{"olderThan":"2592000s"}}]'
```

---

## Cloud Build

```yaml
# cloudbuild.yaml
steps:
# Run tests
- name: python:3.12-slim
  entrypoint: bash
  args: ['-c', 'pip install -r requirements.txt && pytest tests/']

# Build image
- name: gcr.io/cloud-builders/docker
  args:
  - build
  - -t
  - $_REGION-docker.pkg.dev/$PROJECT_ID/$_REPO/$_IMAGE:$SHORT_SHA
  - --cache-from
  - $_REGION-docker.pkg.dev/$PROJECT_ID/$_REPO/$_IMAGE:latest
  - .

# Push image
- name: gcr.io/cloud-builders/docker
  args:
  - push
  - $_REGION-docker.pkg.dev/$PROJECT_ID/$_REPO/$_IMAGE:$SHORT_SHA

# Deploy to GKE
- name: gcr.io/google.com/cloudsdktool/cloud-sdk
  entrypoint: bash
  args:
  - -c
  - |
    gcloud container clusters get-credentials $_CLUSTER --region $_REGION
    kubectl set image deployment/myapp app=$_REGION-docker.pkg.dev/$PROJECT_ID/$_REPO/$_IMAGE:$SHORT_SHA -n production
    kubectl rollout status deployment/myapp -n production

images:
- $_REGION-docker.pkg.dev/$PROJECT_ID/$_REPO/$_IMAGE:$SHORT_SHA

substitutions:
  _REGION: us-central1
  _REPO: my-docker-repo
  _IMAGE: myapp
  _CLUSTER: my-cluster

options:
  logging: CLOUD_LOGGING_ONLY
  machineType: E2_HIGHCPU_8
```

---

## Cloud Deploy — Managed Progressive Delivery

```yaml
# delivery-pipeline.yaml
apiVersion: deploy.cloud.google.com/v1
kind: DeliveryPipeline
metadata:
  name: myapp-pipeline
  location: us-central1
serialPipeline:
  stages:
  - targetId: staging
    profiles: [staging]
  - targetId: production
    profiles: [production]

---
apiVersion: deploy.cloud.google.com/v1
kind: Target
metadata:
  name: staging
spec:
  gke:
    cluster: projects/myproject/locations/us-central1/clusters/staging

---
apiVersion: deploy.cloud.google.com/v1
kind: Target
metadata:
  name: production
spec:
  requireApproval: true    # Manual approval gate
  gke:
    cluster: projects/myproject/locations/us-central1/clusters/production
```

```bash
# Apply pipeline
gcloud deploy apply --file=delivery-pipeline.yaml --region=us-central1

# Create release (deploys to staging automatically)
gcloud deploy releases create release-v1 \
  --delivery-pipeline=myapp-pipeline \
  --region=us-central1 \
  --images=myapp=$REGION-docker.pkg.dev/$PROJECT/repo/myapp:abc1234

# Approve for production
gcloud deploy releases promote --release=release-v1 \
  --delivery-pipeline=myapp-pipeline \
  --region=us-central1
```

---

## Workload Identity Federation

```bash
PROJECT=$(gcloud config get-value project)
CLUSTER="my-cluster"
REGION="us-central1"
K8S_SA="myapp-k8s-sa"
GCP_SA="myapp-gcp-sa"
NAMESPACE="production"

# 1. Enable Workload Identity on cluster
gcloud container clusters update $CLUSTER \
  --workload-pool=$PROJECT.svc.id.goog \
  --region=$REGION

# 2. Create GCP Service Account
gcloud iam service-accounts create $GCP_SA

# 3. Grant GCP SA the permissions it needs
gcloud projects add-iam-policy-binding $PROJECT \
  --role roles/secretmanager.secretAccessor \
  --member "serviceAccount:$GCP_SA@$PROJECT.iam.gserviceaccount.com"

# 4. Bind K8s SA to GCP SA
gcloud iam service-accounts add-iam-policy-binding \
  $GCP_SA@$PROJECT.iam.gserviceaccount.com \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:$PROJECT.svc.id.goog[$NAMESPACE/$K8S_SA]"

# 5. Create annotated K8s SA
kubectl create serviceaccount $K8S_SA -n $NAMESPACE
kubectl annotate serviceaccount $K8S_SA -n $NAMESPACE \
  iam.gke.io/gcp-service-account=$GCP_SA@$PROJECT.iam.gserviceaccount.com

# 6. Verify (pod should be able to access Secret Manager)
kubectl run test --image=google/cloud-sdk:slim --rm -it \
  --serviceaccount=$K8S_SA -n $NAMESPACE \
  -- gcloud secrets list
```

---

## Secret Manager Integration

```bash
# Create a secret
echo -n "mysecretvalue" | gcloud secrets create my-secret --data-file=-

# Grant access to K8s workloads
gcloud secrets add-iam-policy-binding my-secret \
  --role roles/secretmanager.secretAccessor \
  --member "serviceAccount:$GCP_SA@$PROJECT.iam.gserviceaccount.com"

# Access in application (Python)
# from google.cloud import secretmanager
# client = secretmanager.SecretManagerServiceClient()
# name = f"projects/{project_id}/secrets/my-secret/versions/latest"
# value = client.access_secret_version(name=name).payload.data.decode("UTF-8")

# Mount via Secret Store CSI
gcloud components install kubectl
kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/secrets-store-csi-driver-provider-gcp/main/deploy/provider-gcp-plugin.yaml
```

---

## Cloud Monitoring and Logging

```bash
# Query logs (gcloud CLI)
gcloud logging read \
  'resource.type="k8s_container" AND severity=ERROR' \
  --limit=50 \
  --format="value(textPayload)"

# Create alert policy
gcloud alpha monitoring policies create --policy-from-file=alert-policy.json

# alert-policy.json:
# {
#   "displayName": "High Error Rate",
#   "conditions": [{
#     "displayName": "Error rate > 1%",
#     "conditionThreshold": {
#       "filter": "metric.type=\"custom.googleapis.com/myapp/error_rate\"",
#       "comparison": "COMPARISON_GT",
#       "thresholdValue": 0.01,
#       "duration": "300s"
#     }
#   }],
#   "notificationChannels": ["projects/PROJECT/notificationChannels/CHANNEL_ID"]
# }
```
