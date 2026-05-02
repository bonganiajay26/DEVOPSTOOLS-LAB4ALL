# Azure DevOps Core Services

## Platform Overview

```
Azure DevOps = Complete end-to-end DevOps platform by Microsoft

┌─────────────────────────────────────────────────────────────┐
│                      Azure DevOps                           │
│                                                             │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  │
│  │  Boards  │  │  Repos   │  │ Pipelines│  │Artifacts │  │
│  │ (Kanban/ │  │  (Git)   │  │ (CI/CD)  │  │ (Packages│  │
│  │  Scrum)  │  │          │  │          │  │  Registry│  │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘  │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Test Plans (QA Management)              │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

---

## Service Comparison

| Azure DevOps Service | AWS Equivalent | GCP Equivalent | Purpose |
|---------------------|---------------|----------------|---------|
| Azure Pipelines | CodePipeline + CodeBuild | Cloud Build | CI/CD |
| Azure Repos | CodeCommit | Cloud Source Repos | Git hosting |
| Azure Artifacts | CodeArtifact | Artifact Registry | Package registry |
| Azure Boards | Jira (partner) | — | Sprint/work tracking |
| AKS | EKS | GKE | Kubernetes |
| ACR | ECR | Artifact Registry | Container registry |
| Azure Key Vault | Secrets Manager | Secret Manager | Secret storage |
| Azure Monitor | CloudWatch | Cloud Monitoring | Observability |
| Azure Active Directory | IAM Identity Center | Cloud IAM | Identity |

---

## Azure Pipelines — Key Concepts

### Pipeline Stages

```yaml
# Multi-stage pipeline
stages:
- stage: Build
  jobs:
  - job: BuildJob
    steps: [...]

- stage: Test
  dependsOn: Build
  jobs:
  - job: TestJob

- stage: Deploy_Staging
  dependsOn: Test
  condition: and(succeeded(), eq(variables['Build.SourceBranch'], 'refs/heads/main'))
  jobs:
  - deployment: DeployStaging
    environment: staging      # Triggers approval gate if configured
    strategy:
      runOnce:
        deploy:
          steps: [...]

- stage: Deploy_Production
  dependsOn: Deploy_Staging
  jobs:
  - deployment: DeployProd
    environment: production   # Requires human approval
```

### Agents

```yaml
# Microsoft-hosted agents (free tier available)
pool:
  vmImage: ubuntu-latest    # ubuntu-latest, windows-latest, macos-latest

# Self-hosted agents (your own machines)
pool:
  name: MyPool
  demands:
  - docker
  - gpu

# Azure Virtual Machine Scale Set agents (auto-scaling pool)
pool:
  name: VMSS-Pool
```

### Service Connections

```yaml
# Service connections: pre-configured credentials in Azure DevOps
# Setup: Project Settings → Service Connections

# Docker registry (ACR)
- task: Docker@2
  inputs:
    containerRegistry: 'my-acr-connection'   # Service connection name
    repository: myapp
    command: buildAndPush
    tags: $(Build.BuildId)

# Kubernetes
- task: KubernetesManifest@1
  inputs:
    kubernetesServiceConnection: 'my-aks-connection'
    namespace: production
    manifests: k8s/

# AWS (via service connection)
- task: AmazonWebServices.aws-vsts-tools.AWSCLI.AWSCLI@1
  inputs:
    awsCredentials: 'my-aws-connection'
    regionName: us-east-1
    awsCommand: s3 ls
```

---

## AKS — Azure Kubernetes Service

```bash
# Create AKS cluster (CLI)
az aks create \
  --resource-group myRG \
  --name myCluster \
  --node-count 3 \
  --enable-addons monitoring \
  --generate-ssh-keys \
  --node-vm-size Standard_D4s_v5 \
  --kubernetes-version 1.29 \
  --enable-workload-identity \
  --enable-oidc-issuer

# Get credentials
az aks get-credentials --resource-group myRG --name myCluster

# Browse cluster
kubectl get nodes
```

### AKS Add-ons

```bash
# Azure Monitor Container Insights (built-in monitoring)
az aks enable-addons --addons monitoring --name myCluster --resource-group myRG

# Azure Policy add-on (OPA/Gatekeeper)
az aks enable-addons --addons azure-policy --name myCluster --resource-group myRG

# Secret Store CSI (Key Vault integration)
az aks enable-addons --addons azure-keyvault-secrets-provider \
  --name myCluster --resource-group myRG
```

---

## ACR — Azure Container Registry

```bash
# Create registry
az acr create --resource-group myRG --name myacr --sku Premium

# Login
az acr login --name myacr

# Build and push (ACR Tasks — no Docker needed locally!)
az acr build --registry myacr --image myapp:v1 .

# Enable geo-replication (Premium SKU)
az acr replication create --location westus --registry myacr

# Enable vulnerability scanning
az acr update --name myacr --allow-trusted-services true

# Attach to AKS (grants pull permissions automatically)
az aks update --name myCluster --resource-group myRG \
  --attach-acr myacr
```

---

## Azure Key Vault

```bash
# Create Key Vault
az keyvault create \
  --name myapp-kv \
  --resource-group myRG \
  --location eastus \
  --sku premium \
  --enable-purge-protection

# Add secrets
az keyvault secret set --vault-name myapp-kv \
  --name DatabasePassword --value "mysecretpassword"

az keyvault secret set --vault-name myapp-kv \
  --name ApiKey --value "sk-abc123"

# Get secret
az keyvault secret show --vault-name myapp-kv --name DatabasePassword

# Use in Azure Pipelines (Key Vault task)
```

```yaml
# Azure Pipelines: link Key Vault to variable group
# Library → Variable Groups → Link secrets from Key Vault

variables:
- group: production-keyvault-secrets   # Contains Key Vault-linked secrets

steps:
- script: echo "DB password is $(DatabasePassword)"
  # Note: masked in logs
```

---

## Azure Active Directory Integration

```bash
# AKS RBAC integrated with Azure AD
# Users log in with their Azure AD credentials — no separate kubeconfig management

# Create AKS with Azure AD RBAC
az aks create \
  --name myCluster \
  --resource-group myRG \
  --enable-aad \
  --enable-azure-rbac

# Grant user access to AKS
az role assignment create \
  --assignee user@company.com \
  --role "Azure Kubernetes Service Cluster User Role" \
  --scope /subscriptions/$SUBSCRIPTION/resourceGroups/myRG/providers/Microsoft.ContainerService/managedClusters/myCluster

# Assign K8s RBAC role
kubectl create clusterrolebinding dev-view \
  --clusterrole=view \
  --user=user@company.com
```

---

## Variable Groups and Secrets

```yaml
# Pipeline: use variable groups
variables:
- group: common-variables          # Non-sensitive config
- group: production-secrets        # Key Vault linked secrets
- name: imageTag
  value: $(Build.BuildId)

# Reference in steps
steps:
- script: |
    docker build -t $(ACR_NAME).azurecr.io/myapp:$(imageTag) .
    docker push $(ACR_NAME).azurecr.io/myapp:$(imageTag)
  env:
    ACR_NAME: $(AcrName)           # From variable group
```

---

## Pipeline Caching

```yaml
# Cache node_modules across runs
- task: Cache@2
  inputs:
    key: '"npm" | "$(Agent.OS)" | package-lock.json'
    restoreKeys: |
      "npm" | "$(Agent.OS)"
    path: $(npm_config_cache)
  displayName: Cache npm

- script: npm ci
  displayName: Install dependencies

# Cache Docker layers
- task: Cache@2
  inputs:
    key: '"docker" | "$(Agent.OS)" | Dockerfile'
    restoreKeys: '"docker" | "$(Agent.OS)"'
    path: $(Pipeline.Workspace)/docker-cache
    cacheHitVar: CACHE_RESTORED

- task: Docker@2
  inputs:
    command: build
    repository: myapp
    tags: $(Build.BuildId)
    arguments: >
      --cache-from type=local,src=$(Pipeline.Workspace)/docker-cache
      --cache-to type=local,dest=$(Pipeline.Workspace)/docker-cache,mode=max
```
