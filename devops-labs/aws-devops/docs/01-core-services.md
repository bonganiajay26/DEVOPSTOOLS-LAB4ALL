# AWS DevOps Core Services

## Platform Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    AWS DevOps Ecosystem                      │
│                                                             │
│  CI/CD Pipeline:                                            │
│  CodePipeline → CodeBuild → CodeDeploy → EKS/ECS/EC2       │
│                                                             │
│  Container Services:                                        │
│  ECR (registry) → EKS (K8s) / ECS (managed containers)     │
│                                                             │
│  Infrastructure:                                            │
│  CloudFormation / CDK / Terraform (state in S3)             │
│                                                             │
│  Observability:                                             │
│  CloudWatch (metrics+logs) → X-Ray (traces)                 │
│                                                             │
│  Secrets & Config:                                          │
│  Secrets Manager + Parameter Store + KMS                    │
│                                                             │
│  Identity:                                                  │
│  IAM + IRSA (pod-level AWS auth for K8s)                    │
└─────────────────────────────────────────────────────────────┘
```

---

## Key DevOps Services

### AWS CodePipeline
Orchestrates CI/CD workflow. Connects source → build → test → deploy.

```
GitHub (source) → CodeBuild (build/test) → ECR (push) → EKS (deploy)
                                         ↓
                                  Manual Approval → Production
```

### AWS CodeBuild
Managed build service. Runs your buildspec.yml in a container.

```yaml
# buildspec.yml
version: 0.2
env:
  variables:
    AWS_REGION: us-east-1
  parameter-store:
    DB_PASSWORD: /myapp/production/db-password   # From Parameter Store

phases:
  install:
    runtime-versions:
      python: 3.12
    commands:
    - pip install -r requirements.txt

  pre_build:
    commands:
    - echo "Logging in to ECR..."
    - aws ecr get-login-password | docker login --username AWS \
        --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
    - COMMIT_HASH=$(echo $CODEBUILD_RESOLVED_SOURCE_VERSION | cut -c1-7)
    - IMAGE_TAG=${COMMIT_HASH:=latest}

  build:
    commands:
    - echo "Running tests..."
    - pytest tests/ -v
    - echo "Building Docker image..."
    - docker build -t $REPOSITORY_URI:$IMAGE_TAG --target production .

  post_build:
    commands:
    - docker push $REPOSITORY_URI:$IMAGE_TAG
    - echo "[{\"name\":\"app\",\"imageUri\":\"$REPOSITORY_URI:$IMAGE_TAG\"}]" \
        > imagedefinitions.json

artifacts:
  files:
  - imagedefinitions.json
  - k8s/**

cache:
  paths:
  - /root/.cache/pip/**/*
```

### Amazon EKS
Managed Kubernetes. AWS handles control plane; you manage worker nodes (or use Fargate/Autopilot).

```bash
# Create cluster with eksctl
eksctl create cluster \
  --name production \
  --region us-east-1 \
  --nodegroup-name workers \
  --node-type m5.xlarge \
  --nodes 3 \
  --nodes-min 2 \
  --nodes-max 10 \
  --managed                    # EKS managed node groups

# Or use Terraform (see examples/)
```

### Amazon ECR
Private Docker registry. Fully integrated with AWS IAM.

```bash
# Create repository
aws ecr create-repository \
  --repository-name myapp \
  --image-scanning-configuration scanOnPush=true \
  --region us-east-1

# Lifecycle policy (keep last 20 images)
aws ecr put-lifecycle-policy \
  --repository-name myapp \
  --lifecycle-policy-text '{
    "rules": [{
      "rulePriority": 1,
      "selection": {"tagStatus": "any", "countType": "imageCountMoreThan", "countNumber": 20},
      "action": {"type": "expire"}
    }]
  }'

# Login
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  $AWS_ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com
```

---

## IRSA — IAM Roles for Service Accounts

The most important AWS + K8s integration pattern.

```
Without IRSA: All pods on a node share the node's IAM role (over-privileged)
With IRSA:    Each pod gets its own IAM role via OIDC token (least-privilege)
```

```bash
# Step 1: Enable OIDC on EKS cluster
eksctl utils associate-iam-oidc-provider \
  --cluster production --approve

# Step 2: Create service account with IAM role
eksctl create iamserviceaccount \
  --name myapp-sa \
  --namespace production \
  --cluster production \
  --attach-policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess \
  --approve

# Step 3: Use in pod
# apiVersion: v1
# kind: Pod
# spec:
#   serviceAccountName: myapp-sa   ← Gets temporary AWS credentials automatically
#   containers:
#   - name: app
#     image: myapp
#     # AWS SDK auto-discovers credentials via mounted token
```

---

## Secrets Manager Integration with EKS

```yaml
# External Secrets Operator + AWS Secrets Manager
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: aws-secretsmanager
  namespace: production
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
      auth:
        serviceAccount:
          name: external-secrets-sa   # IRSA service account

---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: myapp-secrets
  namespace: production
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secretsmanager
    kind: SecretStore
  target:
    name: myapp-secrets    # Creates K8s Secret with this name
  data:
  - secretKey: db-password
    remoteRef:
      key: production/myapp/database
      property: password
  - secretKey: api-key
    remoteRef:
      key: production/myapp/api
      property: key
```

---

## CloudWatch Container Insights

```bash
# Enable Container Insights on EKS (sends metrics and logs to CloudWatch)
ClusterName=production
RegionName=us-east-1
FluentBitHttpPort='2020'
FluentBitReadFromHead='Off'

curl https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/quickstart/cwagent-fluent-bit-quickstart.yaml | \
  sed "s/{{cluster_name}}/${ClusterName}/;s/{{region_name}}/${RegionName}/;s/{{http_server_toggle}}/"\"${FluentBitHttpPort}\""/;s/{{http_server_port}}/"\"${FluentBitHttpPort}\""/;s/{{read_from_head}}/"\"${FluentBitReadFromHead}\""/;s/{{read_from_tail}}/On/" | \
  kubectl apply -f -

# Useful CloudWatch queries (Logs Insights):
# Find pods with high restart count:
# fields @timestamp, kubernetes.pod_name, kubernetes.namespace_name
# | filter kubernetes.container_restart_count > 5
# | sort @timestamp desc
```

---

## AWS Cost Optimization for EKS

```bash
# 1. Karpenter (better than Cluster Autoscaler)
helm repo add karpenter https://charts.karpenter.sh/
helm upgrade --install karpenter karpenter/karpenter \
  --namespace karpenter --create-namespace \
  --set settings.aws.clusterName=production

# 2. Spot instances (80% cost saving for stateless workloads)
# NodePool: use Spot instances, fallback to On-Demand
kubectl apply -f - << 'EOF'
apiVersion: karpenter.sh/v1alpha5
kind: Provisioner
spec:
  requirements:
  - key: karpenter.sh/capacity-type
    operator: In
    values: ["spot", "on-demand"]
  - key: node.kubernetes.io/instance-type
    operator: In
    values: [m5.large, m5.xlarge, m5a.xlarge]
EOF

# 3. Scale down non-prod at night
kubectl scale deployment --all --replicas=0 -n development
# Or use KEDA with cron scaler
```
