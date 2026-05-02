# GCP DevOps

> **Google Cloud Platform DevOps: GKE, Cloud Build, Artifact Registry, Cloud Run, and beyond.**

---

## Quick Navigation

| Section | Contents |
|---------|----------|
| [docs/01-core-services.md](docs/01-core-services.md) | GKE, Cloud Build, Artifact Registry, IAM, Workload Identity |
| [examples/](examples/) | Cloud Build pipelines, GKE configs |
| [labs/](labs/) | Deploy to GKE, Cloud Run, build pipeline |
| [interview-prep/questions.md](interview-prep/questions.md) | 15 interview Q&A |

---

## Core GCP DevOps Services

| GCP Service | AWS Equivalent | Azure Equivalent |
|-------------|---------------|-----------------|
| GKE | EKS | AKS |
| Artifact Registry | ECR | ACR |
| Cloud Build | CodeBuild | Azure Pipelines |
| Cloud Deploy | CodeDeploy | Azure Pipelines Environments |
| Cloud Run | Fargate | Container Apps |
| Secret Manager | Secrets Manager | Key Vault |
| Cloud Monitoring | CloudWatch | Azure Monitor |
| Cloud Logging | CloudWatch Logs | Log Analytics |
| IAM Workload Identity | IRSA | Workload Identity |

---

## Quick Start

```bash
# Authenticate
gcloud auth login
gcloud config set project my-project

# Create GKE cluster (Autopilot — fully managed)
gcloud container clusters create-auto my-cluster \
  --region us-central1

# Workload Identity setup
gcloud iam service-accounts create my-app-sa
gcloud projects add-iam-policy-binding my-project \
  --role roles/secretmanager.secretAccessor \
  --member "serviceAccount:my-app-sa@my-project.iam.gserviceaccount.com"

# Bind K8s SA to GCP SA
gcloud iam service-accounts add-iam-policy-binding my-app-sa@my-project.iam.gserviceaccount.com \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:my-project.svc.id.goog[production/my-k8s-sa]"

kubectl annotate serviceaccount my-k8s-sa -n production \
  iam.gke.io/gcp-service-account=my-app-sa@my-project.iam.gserviceaccount.com
```
