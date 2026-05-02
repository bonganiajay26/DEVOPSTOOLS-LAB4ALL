# Azure DevOps

> **Microsoft's complete DevOps platform: Boards, Repos, Pipelines, Artifacts, and Test Plans.**

---

## Quick Navigation

| Section | Contents |
|---------|----------|
| [docs/01-core-services.md](docs/01-core-services.md) | Pipelines, AKS, ACR, Key Vault, RBAC |
| [examples/](examples/) | Azure Pipelines YAML, AKS configs |
| [labs/](labs/) | Deploy to AKS, Key Vault integration |
| [interview-prep/questions.md](interview-prep/questions.md) | 15 interview Q&A |

---

## Azure DevOps Pipelines Quick Start

```yaml
# azure-pipelines.yml
trigger:
  branches:
    include: [main]

pool:
  vmImage: ubuntu-latest

stages:
- stage: Test
  jobs:
  - job: RunTests
    steps:
    - task: UsePythonVersion@0
      inputs:
        versionSpec: "3.12"
    - script: pip install -r requirements.txt && pytest
      displayName: Run tests

- stage: Build
  dependsOn: Test
  jobs:
  - job: BuildAndPush
    steps:
    - task: Docker@2
      inputs:
        command: buildAndPush
        repository: myapp
        dockerfile: Dockerfile
        containerRegistry: myACRServiceConnection
        tags: |
          $(Build.SourceVersion)
          latest

- stage: DeployAKS
  dependsOn: Build
  jobs:
  - deployment: Deploy
    environment: production     # Requires approval gate
    strategy:
      runOnce:
        deploy:
          steps:
          - task: KubernetesManifest@1
            inputs:
              action: deploy
              namespace: production
              manifests: k8s/deployment.yaml
              containers: myacr.azurecr.io/myapp:$(Build.SourceVersion)
```

---

## Core Azure DevOps Services

| Service | AWS Equivalent | Purpose |
|---------|---------------|---------|
| Azure Boards | Jira | Sprint planning, work items |
| Azure Repos | GitHub | Git repositories |
| Azure Pipelines | CodePipeline/GitHub Actions | CI/CD |
| Azure Artifacts | CodeArtifact | npm/NuGet/Maven packages |
| AKS | EKS | Managed Kubernetes |
| ACR | ECR | Container registry |
| Key Vault | Secrets Manager | Secret management |
| Azure Monitor | CloudWatch | Metrics and logs |

---

## Key Vault Integration with AKS

```bash
# Use Azure Workload Identity (replaces Pod Managed Identity)
az aks update --name my-cluster --resource-group my-rg \
  --enable-workload-identity --enable-oidc-issuer

# Create managed identity
az identity create --name my-app-identity --resource-group my-rg

# Grant Key Vault access
az keyvault set-policy --name my-vault \
  --object-id $(az identity show --name my-app-identity --query principalId -o tsv) \
  --secret-permissions get list

# Pods can now read secrets from Key Vault without credentials
```
