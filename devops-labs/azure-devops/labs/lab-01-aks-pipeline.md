# Lab 01: Build and Deploy to AKS with Azure Pipelines

**Difficulty**: Intermediate | **Time**: 60 minutes  
**Goal**: Create an Azure Pipeline that builds a Docker image, pushes to ACR, and deploys to AKS.

---

## Prerequisites

```bash
# Install Azure CLI
brew install azure-cli   # macOS
# or https://docs.microsoft.com/en-us/cli/azure/install-azure-cli

# Login
az login
az account show   # Verify subscription

# Install kubectl
az aks install-cli
```

---

## Part 1: Setup Azure Resources

```bash
RG="aks-lab-rg"
LOCATION="eastus"
ACR="akslabacr$RANDOM"
AKS="aks-lab-cluster"

# Resource Group
az group create --name $RG --location $LOCATION

# Azure Container Registry
az acr create --resource-group $RG --name $ACR --sku Basic
echo "ACR: $ACR.azurecr.io"

# AKS Cluster
az aks create \
  --resource-group $RG \
  --name $AKS \
  --node-count 2 \
  --generate-ssh-keys \
  --attach-acr $ACR        # Grant AKS permission to pull from ACR
  
# Get credentials
az aks get-credentials --resource-group $RG --name $AKS
kubectl get nodes
```

---

## Part 2: Create the Application

```bash
mkdir azure-lab && cd azure-lab
git init

cat > app.py << 'EOF'
from flask import Flask, jsonify
import os

app = Flask(__name__)

@app.route("/health")
def health():
    return jsonify({"status": "healthy", "version": os.getenv("VERSION", "1.0")})

@app.route("/")
def index():
    return jsonify({"message": "Hello from AKS!", "env": os.getenv("APP_ENV", "dev")})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
EOF

cat > requirements.txt << 'EOF'
flask==3.0.0
gunicorn==21.2.0
EOF

cat > Dockerfile << 'EOF'
FROM python:3.12-slim
WORKDIR /app
RUN useradd -m appuser
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
USER appuser
EXPOSE 8080
HEALTHCHECK CMD curl -f http://localhost:8080/health || exit 1
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "app:app"]
EOF

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
        image: IMAGE_PLACEHOLDER   # Replaced by pipeline
        ports:
        - containerPort: 8080
        env:
        - name: APP_ENV
          value: production
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: flask-app
  namespace: production
spec:
  selector:
    app: flask-app
  ports:
  - port: 80
    targetPort: 8080
  type: LoadBalancer
EOF

kubectl create namespace production
```

---

## Part 3: Create Azure Pipeline

```bash
# Create azure-pipelines.yml
cat > azure-pipelines.yml << 'EOF'
trigger:
  branches:
    include: [main]

variables:
  acrName: YOUR_ACR_NAME            # Replace with your ACR name
  imageRepo: flask-app
  tag: $(Build.BuildId)

pool:
  vmImage: ubuntu-latest

stages:
- stage: Build
  jobs:
  - job: BuildAndPush
    steps:
    - task: Docker@2
      displayName: Build and push to ACR
      inputs:
        containerRegistry: 'acr-service-connection'  # Create this in Azure DevOps
        repository: $(imageRepo)
        command: buildAndPush
        Dockerfile: Dockerfile
        tags: |
          $(tag)
          latest

- stage: Deploy
  dependsOn: Build
  jobs:
  - deployment: DeployToAKS
    environment: production
    strategy:
      runOnce:
        deploy:
          steps:
          - task: AzureCLI@2
            displayName: Deploy to AKS
            inputs:
              azureSubscription: 'azure-service-connection'
              scriptType: bash
              scriptLocation: inlineScript
              inlineScript: |
                az aks get-credentials --resource-group aks-lab-rg --name aks-lab-cluster

                # Update the image in the deployment manifest
                sed -i "s|IMAGE_PLACEHOLDER|$(acrName).azurecr.io/$(imageRepo):$(tag)|g" k8s/deployment.yaml

                kubectl apply -f k8s/
                kubectl rollout status deployment/flask-app -n production --timeout=5m

                # Get public IP
                echo "Service IP:"
                kubectl get svc flask-app -n production
EOF

git add .
git commit -m "feat: add Flask app and Azure pipeline"
```

---

## Part 4: Connect Azure DevOps to Azure

```bash
# In Azure DevOps:
# 1. Go to Project Settings → Service Connections
# 2. Create "Azure Resource Manager" connection → name: azure-service-connection
# 3. Create "Docker Registry" connection → Azure Container Registry → name: acr-service-connection

# Import repo to Azure DevOps:
# Repos → Import → https://github.com/... or upload local files

# OR create pipeline from existing azure-pipelines.yml:
# Pipelines → New Pipeline → Azure Repos Git → select repo → Existing YAML
```

---

## Part 5: Run and Verify

```bash
# After pipeline runs:
az aks get-credentials --resource-group aks-lab-rg --name aks-lab-cluster

kubectl get pods -n production
kubectl get svc flask-app -n production

# Get the external IP
EXTERNAL_IP=$(kubectl get svc flask-app -n production \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

curl http://$EXTERNAL_IP/health
curl http://$EXTERNAL_IP/
```

---

## Cleanup

```bash
az group delete --name aks-lab-rg --yes --no-wait
cd ..
rm -rf azure-lab
```

## What You Learned

- [x] Creating AKS cluster and ACR with Azure CLI
- [x] Azure Pipelines multi-stage YAML
- [x] Service Connections for Azure and ACR
- [x] Environment gates in Azure DevOps
- [x] Automated image deployment to AKS
