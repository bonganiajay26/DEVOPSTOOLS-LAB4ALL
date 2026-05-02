# Lab 01: AWS CodePipeline → ECR → EKS Deployment

**Difficulty**: Intermediate | **Time**: 60 minutes  
**Goal**: Build a complete AWS CI/CD pipeline: GitHub → CodeBuild → ECR → EKS.

---

## Prerequisites

```bash
# Install tools
pip install awscli
aws configure   # Enter: Access Key, Secret Key, Region=us-east-1

# Verify
aws sts get-caller-identity
aws eks list-clusters
```

---

## Part 1: Create ECR Repository

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION="us-east-1"
APP="flask-app"

# Create repo
aws ecr create-repository \
  --repository-name $APP \
  --image-scanning-configuration scanOnPush=true

ECR_URI="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/$APP"
echo "ECR URI: $ECR_URI"

# Test login
aws ecr get-login-password | docker login --username AWS \
  --password-stdin $ACCOUNT.dkr.ecr.$REGION.amazonaws.com
```

---

## Part 2: Create and Push Sample App

```bash
mkdir aws-lab && cd aws-lab

cat > app.py << 'EOF'
from flask import Flask, jsonify
import os, socket

app = Flask(__name__)

@app.route("/health")
def health():
    return jsonify({"status": "healthy", "host": socket.gethostname()})

@app.route("/")
def index():
    return jsonify({"message": "Hello from EKS!", "version": os.getenv("APP_VERSION", "1.0")})

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
COPY app.py .
USER appuser
EXPOSE 8080
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "app:app"]
EOF

# Build and push manually (what CodeBuild will automate)
docker build -t $ECR_URI:manual .
docker push $ECR_URI:manual
echo "Image pushed: $ECR_URI:manual"
```

---

## Part 3: Create buildspec.yml

```bash
cat > buildspec.yml << 'EOF'
version: 0.2

env:
  variables:
    AWS_DEFAULT_REGION: us-east-1
    IMAGE_REPO_NAME: flask-app
    EKS_CLUSTER_NAME: my-cluster
    EKS_NAMESPACE: production

phases:
  pre_build:
    commands:
    - echo "Getting AWS Account ID..."
    - ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    - ECR_URI="$ACCOUNT_ID.dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com/$IMAGE_REPO_NAME"
    - IMAGE_TAG="$CODEBUILD_RESOLVED_SOURCE_VERSION"
    - echo "Logging in to ECR..."
    - aws ecr get-login-password | docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com
    - echo "Running tests..."
    - pip install pytest flask && pytest tests/ -v

  build:
    commands:
    - echo "Building image $ECR_URI:$IMAGE_TAG"
    - docker build -t $ECR_URI:$IMAGE_TAG --target production .
    - docker tag $ECR_URI:$IMAGE_TAG $ECR_URI:latest

  post_build:
    commands:
    - echo "Pushing image..."
    - docker push $ECR_URI:$IMAGE_TAG
    - docker push $ECR_URI:latest
    - echo "Updating kubeconfig for EKS..."
    - aws eks update-kubeconfig --region $AWS_DEFAULT_REGION --name $EKS_CLUSTER_NAME
    - echo "Deploying to EKS..."
    - kubectl set image deployment/flask-app app=$ECR_URI:$IMAGE_TAG -n $EKS_NAMESPACE
    - kubectl rollout status deployment/flask-app -n $EKS_NAMESPACE --timeout=5m
    - echo "Deploy complete!"
    - printf '[{"name":"app","imageUri":"%s"}]' $ECR_URI:$IMAGE_TAG > imagedefinitions.json

artifacts:
  files:
  - imagedefinitions.json
  - k8s/**

cache:
  paths:
  - /root/.cache/pip/**/*
EOF
```

---

## Part 4: Create K8s Manifests

```bash
mkdir k8s

cat > k8s/deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: flask-app
  namespace: production
spec:
  replicas: 2
  selector:
    matchLabels:
      app: flask-app
  template:
    metadata:
      labels:
        app: flask-app
    spec:
      containers:
      - name: app
        image: PLACEHOLDER   # Updated by CodeBuild
        ports:
        - containerPort: 8080
        env:
        - name: APP_VERSION
          value: "1.0"
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
  name: flask-app
  namespace: production
spec:
  type: LoadBalancer
  selector:
    app: flask-app
  ports:
  - port: 80
    targetPort: 8080
EOF

# Apply initial deployment
aws eks update-kubeconfig --name my-cluster --region us-east-1
kubectl create namespace production 2>/dev/null || true
sed "s|PLACEHOLDER|$ECR_URI:manual|" k8s/deployment.yaml | kubectl apply -f -
kubectl get pods -n production
```

---

## Part 5: Create CodeBuild Project

```bash
# IAM role for CodeBuild
cat > codebuild-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "codebuild.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws iam create-role \
  --role-name CodeBuildEKSRole \
  --assume-role-policy-document file://codebuild-trust.json

aws iam attach-role-policy \
  --role-name CodeBuildEKSRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser

# Also need EKS describe/update permissions (create a custom policy)

# Create CodeBuild project
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

aws codebuild create-project \
  --name flask-app-build \
  --source "type=GITHUB,location=https://github.com/YOUR_USERNAME/aws-lab" \
  --artifacts "type=NO_ARTIFACTS" \
  --environment "type=LINUX_CONTAINER,computeType=BUILD_GENERAL1_SMALL,image=aws/codebuild/standard:7.0,privilegedMode=true" \
  --service-role arn:aws:iam::$ACCOUNT:role/CodeBuildEKSRole \
  --region us-east-1

# Trigger a build manually
aws codebuild start-build --project-name flask-app-build
aws codebuild list-builds-for-project --project-name flask-app-build
```

---

## Part 6: Create the Full CodePipeline

```bash
# Create S3 bucket for artifacts
aws s3 mb s3://codepipeline-artifacts-$ACCOUNT-us-east-1

# Create pipeline (simplified - full version uses CloudFormation)
aws codepipeline create-pipeline --cli-input-json '{
  "pipeline": {
    "name": "flask-app-pipeline",
    "roleArn": "arn:aws:iam::'"$ACCOUNT"':role/CodePipelineRole",
    "artifactStore": {
      "type": "S3",
      "location": "codepipeline-artifacts-'"$ACCOUNT"'-us-east-1"
    },
    "stages": [
      {
        "name": "Source",
        "actions": [{
          "name": "GitHub",
          "actionTypeId": {
            "category": "Source",
            "owner": "ThirdParty",
            "provider": "GitHub",
            "version": "1"
          },
          "configuration": {
            "Owner": "YOUR_GITHUB_USERNAME",
            "Repo": "aws-lab",
            "Branch": "main",
            "OAuthToken": "'"$GITHUB_TOKEN"'"
          },
          "outputArtifacts": [{"name": "SourceArtifact"}]
        }]
      },
      {
        "name": "Build",
        "actions": [{
          "name": "Build",
          "actionTypeId": {
            "category": "Build",
            "owner": "AWS",
            "provider": "CodeBuild",
            "version": "1"
          },
          "configuration": {"ProjectName": "flask-app-build"},
          "inputArtifacts": [{"name": "SourceArtifact"}],
          "outputArtifacts": [{"name": "BuildArtifact"}]
        }]
      }
    ]
  }
}'

# Monitor pipeline execution
aws codepipeline list-pipeline-executions --pipeline-name flask-app-pipeline
```

---

## Cleanup

```bash
aws codepipeline delete-pipeline --name flask-app-pipeline
aws codebuild delete-project --name flask-app-build
aws ecr delete-repository --repository-name flask-app --force
kubectl delete namespace production
cd ..
rm -rf aws-lab
```

## What You Learned

- [x] ECR repository creation and authentication
- [x] buildspec.yml for CodeBuild
- [x] Docker build, test, push in CodeBuild
- [x] EKS kubeconfig in CI/CD (aws eks update-kubeconfig)
- [x] CodePipeline orchestrating source → build → deploy
