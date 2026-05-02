# AWS DevOps

> **End-to-end DevOps on AWS: EKS, CodePipeline, ECR, CloudFormation, and more.**

---

## Quick Navigation

| Section | Contents |
|---------|----------|
| [docs/01-core-services.md](docs/01-core-services.md) | EKS, ECR, CodePipeline, CodeBuild, IAM |
| [docs/02-networking.md](docs/02-networking.md) | VPC, ALB, Route53, WAF |
| [examples/](examples/) | 10 real-world AWS infrastructure examples |
| [labs/](labs/) | Labs: EKS cluster, CodePipeline, IAM |
| [interview-prep/questions.md](interview-prep/questions.md) | 15 interview Q&A |

---

## Core DevOps Services

| Service | Purpose | DevOps Use |
|---------|---------|-----------|
| EKS | Managed Kubernetes | Container orchestration |
| ECR | Container Registry | Store Docker images |
| CodePipeline | CI/CD orchestration | Automate deployments |
| CodeBuild | Build service | Run tests, build images |
| CodeDeploy | Deployment service | EC2/ECS deployments |
| CloudFormation | IaC | Provision AWS resources |
| Systems Manager | Ops management | Patch management, run commands |
| CloudWatch | Monitoring/logging | Metrics, logs, alarms |
| Secrets Manager | Secret storage | Store and rotate secrets |
| IAM | Identity & access | RBAC, IRSA, roles |

---

## Key Patterns

### IRSA — IAM Roles for Service Accounts
```bash
# Give K8s pods AWS IAM permissions without credentials in pods
eksctl create iamserviceaccount \
  --name my-app-sa \
  --namespace production \
  --cluster my-cluster \
  --attach-policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess \
  --approve

# Pod uses SA → gets AWS credentials via OIDC token
```

### ECR Authentication
```bash
# Login to ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  123456789.dkr.ecr.us-east-1.amazonaws.com

# Push image
docker tag myapp:latest 123456789.dkr.ecr.us-east-1.amazonaws.com/myapp:latest
docker push 123456789.dkr.ecr.us-east-1.amazonaws.com/myapp:latest
```
