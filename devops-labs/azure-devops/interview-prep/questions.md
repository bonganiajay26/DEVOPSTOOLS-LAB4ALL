# Azure DevOps Interview Questions

## Q1. What is Azure Workload Identity and how does it replace Pod Managed Identity?

**Pod Managed Identity (deprecated)**: Node-level identity, MIC/NMI components, security concerns.

**Workload Identity** (current): Uses OIDC federation (same pattern as AWS IRSA).

```bash
# Setup
az aks update --name aks-cluster --resource-group my-rg \
  --enable-workload-identity --enable-oidc-issuer

# Get OIDC issuer URL
OIDC_ISSUER=$(az aks show --name aks-cluster --resource-group my-rg \
  --query "oidcIssuerProfile.issuerUrl" -o tsv)

# Create managed identity
az identity create --name myapp-identity --resource-group my-rg

CLIENT_ID=$(az identity show --name myapp-identity --query clientId -o tsv)
PRINCIPAL_ID=$(az identity show --name myapp-identity --query principalId -o tsv)

# Create OIDC federation credential
az identity federated-credential create \
  --name myapp-federated \
  --identity-name myapp-identity \
  --resource-group my-rg \
  --issuer $OIDC_ISSUER \
  --subject "system:serviceaccount:production:myapp-sa"

# Create K8s ServiceAccount with annotation
kubectl create sa myapp-sa -n production
kubectl annotate sa myapp-sa -n production \
  azure.workload.identity/client-id=$CLIENT_ID
```

---

## Q2. Explain Azure Pipelines environments and approval gates.

```yaml
# Environment with approval gate
# Create in: Pipelines → Environments → production → Approvals

stages:
- stage: DeployProd
  jobs:
  - deployment: Production
    environment:
      name: production          # Pauses here for approval
      resourceType: Kubernetes
      resourceName: my-aks-cluster
    strategy:
      runOnce:
        deploy:
          steps:
          - script: kubectl apply -f k8s/

# Branch-based policies (auto-deploy staging, approve production):
# Pipelines → Library → Variable groups (per environment)
# Pipelines → Environments → production → Approvals and checks
#   Required approvers: 1 from group "Senior Engineers"
#   Timeout: 4 hours
#   Instructions: "Verify staging smoke tests passed"
```

---

## Q3. How do you structure Azure Pipelines for a microservices monorepo?

```yaml
# Use path-based triggers
trigger:
  paths:
    include:
    - services/api/**
    - libs/common/**

# Template-based pipeline (reuse across services)
# azure-pipelines.yml (per service)
extends:
  template: ../templates/microservice-pipeline.yml@templates
  parameters:
    serviceName: api
    dockerfilePath: services/api/Dockerfile
    namespace: production

# templates/microservice-pipeline.yml
parameters:
- name: serviceName
  type: string
- name: namespace
  type: string

stages:
- stage: Test
  jobs:
  - job: Test
    steps:
    - script: cd services/${{ parameters.serviceName }} && npm test
```

---

## Q4. How do you use Azure Key Vault with AKS (Secrets Store CSI)?

```bash
# Install Secrets Store CSI Driver with Azure provider
helm repo add csi-secrets-store-provider-azure \
  https://azure.github.io/secrets-store-csi-driver-provider-azure/charts
helm install csi-secrets-store csi-secrets-store-provider-azure/csi-secrets-store-provider-azure \
  --namespace kube-system \
  --set syncSecret.enabled=true  # Also sync as K8s Secret
```

```yaml
# SecretProviderClass — maps Key Vault secrets to pod
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: my-secrets
  namespace: production
spec:
  provider: azure
  parameters:
    usePodIdentity: "false"
    clientID: "$CLIENT_ID"     # Workload Identity client ID
    keyvaultName: my-keyvault
    objects: |
      array:
        - |
          objectName: db-password
          objectType: secret
        - |
          objectName: api-key
          objectType: secret
    tenantId: "$TENANT_ID"
  secretObjects:
  - secretName: app-secrets    # K8s Secret name
    type: Opaque
    data:
    - objectName: db-password
      key: DB_PASSWORD
```

---

## Q5. Explain AKS node pool types and when to use each.

```
System node pool:
  Purpose: Run AKS system components (coredns, metrics-server, Azure CNI)
  Recommendation: At least 2 nodes (HA), Standard_D2s_v3 minimum
  Taints: CriticalAddonsOnly=true:NoSchedule (prevents app pods)

User node pool:
  Purpose: Run application workloads
  Can have multiple pools with different SKUs:
    - Standard_D4s_v3: general purpose workloads
    - Standard_NC6: GPU for ML inference
    - Standard_E8s_v3: memory-optimized for caching

Spot node pool:
  90% discount vs regular
  Interrupted with 30s notice (handle with preStop hook)
  Label: kubernetes.azure.com/scalesetpriority=spot

# Scale node pool
az aks nodepool scale \
  --cluster-name my-cluster \
  --resource-group my-rg \
  --name userpool \
  --node-count 10
```

---

## Q6. How do you implement blue/green deployments with Azure Traffic Manager?

```
Azure Traffic Manager → weighted routing between two AKS services

Production setup:
  Traffic Manager profile
    ├── Endpoint A: 90% → AKS Service (blue, current version)
    └── Endpoint B: 10% → AKS Service (green, new version)

Shift traffic gradually:
  90/10 → monitor error rates → 50/50 → monitor → 0/100

# Traffic Manager profile
az network traffic-manager profile create \
  --name my-tm-profile \
  --resource-group my-rg \
  --routing-method Weighted \
  --unique-dns-name myapp

# Update weights (during deployment)
az network traffic-manager endpoint update \
  --profile-name my-tm-profile \
  --resource-group my-rg \
  --name blue-endpoint \
  --weight 0    # Remove traffic from blue
```

---

## Q7. What is Azure Monitor and how do you use it with AKS?

```bash
# Enable Container Insights (AKS monitoring)
az aks enable-addons \
  --addons monitoring \
  --name my-cluster \
  --resource-group my-rg \
  --workspace-resource-id /subscriptions/.../workspaces/my-la-workspace

# Query with KQL (Kusto Query Language)
# Log Analytics workspace → Logs

# Pod restarts in last 1 hour:
KubePodInventory
| where TimeGenerated > ago(1h)
| where Namespace == "production"
| where PodRestartCount > 0
| summarize Restarts=max(PodRestartCount) by PodName, ContainerName
| order by Restarts desc

# High CPU usage pods:
Perf
| where ObjectName == "K8SContainer"
| where CounterName == "cpuUsageNanoCores"
| summarize avg(CounterValue) by InstanceName, bin(TimeGenerated, 5m)
| where avg_CounterValue > 900000000  # > 0.9 CPU cores

# Set up alerts:
az monitor metrics alert create \
  --name high-cpu \
  --resource-group my-rg \
  --scopes /subscriptions/.../clusters/my-cluster \
  --condition "avg Percentage CPU > 80" \
  --window-size 5m \
  --evaluation-frequency 1m \
  --action-group my-action-group
```

---

## Q8. How do you handle multi-region AKS deployments?

```
Architecture:
  Region A (primary): AKS cluster + RDS primary
  Region B (secondary): AKS cluster + RDS replica

Traffic routing:
  Azure Front Door (global CDN + load balancer)
    → Region A: priority 1 (primary)
    → Region B: priority 2 (failover)

Data replication:
  Azure SQL Geo-replication (sync)
  Azure Redis Geo-replication
  Azure Blob Storage GRS (geo-redundant)

Failover process (automated):
  1. Front Door health probe detects Region A failure
  2. Traffic shifts to Region B (< 1 minute)
  3. Read replica in Region B promoted to primary
  4. App teams notified

GitOps multi-cluster:
  ArgoCD ApplicationSet
  - cluster: aks-eastus (primary)
  - cluster: aks-westus (secondary)
  Same manifest, different cluster
```

---

## Q9. What is Azure Policy and how does it enforce governance on AKS?

```bash
# Azure Policy Add-on for AKS (based on Gatekeeper/OPA)
az aks enable-addons \
  --addons azure-policy \
  --name my-cluster \
  --resource-group my-rg

# Built-in policies:
# "Kubernetes cluster containers should not run as root"
# "Kubernetes cluster pods should only use allowed images from approved registries"
# "Kubernetes cluster containers should use read-only root filesystem"

# Assign policy to subscription/resource group
az policy assignment create \
  --name "no-root-containers" \
  --policy "/providers/Microsoft.Authorization/policyDefinitions/95edb821-..." \
  --scope /subscriptions/$SUBSCRIPTION_ID/resourceGroups/my-rg \
  --enforcement-mode Default  # Audit or Deny

# Custom policy (OPA Gatekeeper ConstraintTemplate):
kubectl apply -f - << 'EOF'
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8srequiredlabels
spec:
  crd:
    spec:
      names:
        kind: K8sRequiredLabels
  targets:
  - target: admission.k8s.gatekeeper.sh
    rego: |
      violation[{"msg": msg}] {
        not input.review.object.metadata.labels["team"]
        msg := "All resources must have a 'team' label"
      }
EOF
```

---

## Q10. How does Azure DevOps integrate with GitHub?

```yaml
# Option 1: Use GitHub as source, Azure Pipelines for CI/CD
trigger:
  - none  # Disable CI trigger in Azure Pipelines

# GitHub Actions webhook → triggers Azure Pipeline
# Or: use GitHub Apps integration in Azure DevOps

# Option 2: GitHub Actions → Azure services
# .github/workflows/deploy-azure.yml
- uses: azure/login@v1
  with:
    creds: ${{ secrets.AZURE_CREDENTIALS }}
    
- uses: azure/aks-set-context@v3
  with:
    resource-group: my-rg
    cluster-name: my-cluster

- uses: azure/k8s-deploy@v5
  with:
    namespace: production
    manifests: k8s/
    images: myacr.azurecr.io/myapp:${{ github.sha }}

# AZURE_CREDENTIALS secret:
# az ad sp create-for-rbac --name "github-actions" \
#   --role contributor \
#   --scopes /subscriptions/$SUB_ID/resourceGroups/my-rg \
#   --sdk-auth
```

---

## Q11. What is Flux vs ArgoCD on AKS?

```
Microsoft's recommendation: Flux v2 (built into AKS GitOps extension)

az k8s-configuration flux create \
  --name cluster-config \
  --cluster-name my-cluster \
  --resource-group my-rg \
  --cluster-type managedClusters \
  --url https://github.com/myorg/gitops \
  --branch main \
  --kustomization name=infra path=./infrastructure prune=true \
  --kustomization name=apps path=./apps dependsOn=infra prune=true

# Benefits of AKS GitOps extension:
# - Azure Policy compliance reporting
# - Azure Monitor integration for drift metrics
# - RBAC via Azure AD
# - No self-management of ArgoCD/Flux
```

---

## Q12. How do you implement cost management for AKS?

```bash
# 1. AKS Cost Analysis (preview)
az aks addon enable --name my-cluster --resource-group my-rg \
  --addon cost-analysis

# 2. Node auto-provisioning (Karpenter equivalent for AKS)
az aks update --name my-cluster --resource-group my-rg \
  --node-provisioning-mode Auto

# 3. Start/stop AKS cluster (dev/staging overnight savings)
az aks stop --name dev-cluster --resource-group my-rg
az aks start --name dev-cluster --resource-group my-rg

# 4. KEDA with Azure Service Bus for scale-to-zero
# ScaledObject: scale to 0 when no messages in queue

# 5. Azure Spot Node Pools
az aks nodepool add \
  --cluster-name my-cluster \
  --resource-group my-rg \
  --name spotpool \
  --priority Spot \
  --eviction-policy Delete \
  --spot-max-price -1 \    # Pay market price
  --node-count 3

# 6. Resource quotas per namespace (team accountability)
# 7. Azure Cost Management + budgets + alerts
```

---

## Q13. What is Azure Container Apps vs AKS?

```
Azure Container Apps:
  Managed serverless container platform
  Built on KEDA + Dapr + Envoy
  No K8s knowledge required
  Scale to zero automatically
  Best for: microservices, event-driven apps, simple workloads

AKS:
  Full managed Kubernetes
  Full control over cluster configuration
  Need K8s expertise
  More complex but more powerful
  Best for: complex workloads, existing K8s expertise, multi-cloud

When Container Apps wins:
  - Startup scaling (scale to zero, 0 → running on request)
  - Simple HTTP/event-driven microservices
  - No need to manage K8s upgrades
  - Built-in Dapr sidecar for service mesh

When AKS wins:
  - Custom network policies
  - Specific K8s operators/CRDs
  - StatefulSets with custom storage
  - Multi-cloud strategy (same YAML for EKS/GKE)
```

---

## Q14. How do you configure Azure DevOps RBAC?

```
Azure DevOps permissions model:
  Organization → Project → Pipeline/Repo/Board

Roles at project level:
  Reader     → read-only
  Contributor → push code, run pipelines
  Project Admin → manage settings, service connections

Pipeline-specific:
  Builder role → run pipelines
  Can restrict: "only senior-engineers can deploy to production"

Service connections:
  Create once, restrict to specific pipelines
  "Project scoped" vs "Organization scoped"

YAML pipeline security:
  Environment resource → approval gates + branch controls
  Variable groups → restrict to specific pipelines
  Agent pools → restrict which pipelines can use self-hosted runners

# Protect production environment:
# Pipelines → Environments → production → Checks
# Add: Required approvers, deployment branch policy (main only)
```

---

## Q15. How do you troubleshoot Azure Pipeline failures?

```bash
# 1. Re-run pipeline with debug logging
# Pipeline → Rerun → Enable system diagnostics
# Adds: SYSTEM_DEBUG=true → verbose output

# 2. Check service connection
# Organization Settings → Service connections → Verify connection

# 3. YAML validation
az pipelines run --name my-pipeline --dry-run

# 4. Agent logs (self-hosted)
# Agent directory: _diag/*.log files

# Common issues:
# "No hosted parallelism" → free tier exhausted → upgrade or self-hosted
# "Service connection failed" → expired credentials → rotate SPN
# "Permission denied on kubectl" → service connection lacks AKS IAM role
# "Docker build failed" → agent needs Docker engine (use vmImage: ubuntu-latest)

# 5. Extend timeout
steps:
- script: ./long-build.sh
  timeoutInMinutes: 60  # Default is 60 for job, adjust per step

# 6. Cache pipeline artifacts
- task: Cache@2
  inputs:
    key: 'pip | $(Agent.OS) | requirements.txt'
    restoreKeys: 'pip | $(Agent.OS)'
    path: $(PIP_CACHE_DIR)
```
