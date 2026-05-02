# GCP DevOps Interview Questions

## Q1. What is GKE Autopilot vs Standard mode?

```
Standard mode:
  You manage: node pools, machine types, sizing, upgrades
  You pay: per node (even idle)
  Flexibility: full control
  Use for: specific hardware (GPU), custom networking, advanced configs

Autopilot mode:
  GKE manages: all nodes, sizing, upgrades, security
  You pay: per pod resource request (not per node)
  Scale to zero: nodes disappear when no pods
  Use for: most production workloads (simpler ops)

# Cost comparison:
# Standard: 3 nodes × $0.10/hour = $72/month min (even if pods use 10%)
# Autopilot: pay for actual pod CPU/memory requests = ~$30/month for same workload

# Create Autopilot
gcloud container clusters create-auto my-cluster --region us-central1

# Create Standard
gcloud container clusters create my-cluster \
  --region us-central1 \
  --machine-type n2-standard-4 \
  --num-nodes 3 \
  --enable-autoscaling --min-nodes 1 --max-nodes 10
```

---

## Q2. How does Workload Identity work in GKE?

```
Workload Identity Federation:
  K8s ServiceAccount ↔ GCP Service Account (via OIDC)
  Pod gets GCP credentials without key files

Steps:
1. Enable Workload Identity on cluster
2. Create GCP service account with necessary IAM roles
3. Create K8s ServiceAccount with annotation pointing to GCP SA
4. Bind GCP SA to K8s SA via IAM policy

gcloud iam service-accounts create my-app-sa \
  --project my-project

# Grant needed GCP permissions
gcloud projects add-iam-policy-binding my-project \
  --role roles/secretmanager.secretAccessor \
  --member "serviceAccount:my-app-sa@my-project.iam.gserviceaccount.com"

# Allow K8s SA to impersonate GCP SA
gcloud iam service-accounts add-iam-policy-binding \
  my-app-sa@my-project.iam.gserviceaccount.com \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:my-project.svc.id.goog[production/my-k8s-sa]"

# Annotate K8s SA
kubectl annotate serviceaccount my-k8s-sa -n production \
  iam.gke.io/gcp-service-account=my-app-sa@my-project.iam.gserviceaccount.com

# Verify
kubectl run test --image=google/cloud-sdk:slim --rm -it \
  --serviceaccount=my-k8s-sa -n production \
  -- gcloud auth print-identity-token
```

---

## Q3. Explain GCP Cloud Run vs GKE.

```
Cloud Run (serverless containers):
  Fully managed, scale to zero
  No cluster management
  Pay per request (100ms increments)
  Max request timeout: 60 minutes
  Sidecars: supported (Cloud Run Jobs)
  Best for: APIs, webhooks, event-driven workloads

GKE (Kubernetes):
  Manage cluster (or use Autopilot)
  Full K8s feature set
  Always-on (or scale to zero with KEDA)
  Stateful workloads (StatefulSets)
  Best for: complex microservices, need K8s ecosystem

# Cloud Run — deploy in seconds
gcloud run deploy my-api \
  --image gcr.io/myproject/my-api:latest \
  --region us-central1 \
  --allow-unauthenticated \
  --min-instances 1 \    # Keep warm for latency
  --max-instances 100 \
  --memory 512Mi \
  --cpu 1 \
  --concurrency 80    # Requests per instance before scaling
```

---

## Q4. How do you implement CI/CD with Cloud Deploy (managed delivery)?

```yaml
# Cloud Deploy — managed progressive delivery
# Defines delivery pipelines with approval gates between stages

# clouddeploy.yaml
apiVersion: deploy.cloud.google.com/v1
kind: DeliveryPipeline
metadata:
  name: my-app-pipeline
  location: us-central1
description: My App delivery pipeline
serialPipeline:
  stages:
  - targetId: staging
    profiles: [staging]
  - targetId: production
    profiles: [production]
    strategy:
      canary:
        runtimeConfig:
          kubernetes:
            gatewayServiceMesh:
              httpRoute: my-app
              service: my-app-service
              deployment: my-app-deployment
        canaryDeployment:
          percentages: [10, 25, 50]   # Progressively increase canary traffic
          verify: true                 # Run verification after each step
---
apiVersion: deploy.cloud.google.com/v1
kind: Target
metadata:
  name: staging
spec:
  gke:
    cluster: projects/my-project/locations/us-central1/clusters/staging-cluster

---
apiVersion: deploy.cloud.google.com/v1
kind: Target
metadata:
  name: production
spec:
  requireApproval: true              # Manual approval gate
  gke:
    cluster: projects/my-project/locations/us-central1/clusters/prod-cluster

# Create release (triggers deployment to staging)
gcloud deploy releases create my-release-001 \
  --delivery-pipeline my-app-pipeline \
  --region us-central1 \
  --images my-app=gcr.io/myproject/my-app:abc1234

# Promote to production (after manual approval)
gcloud deploy releases promote --release my-release-001 \
  --delivery-pipeline my-app-pipeline \
  --region us-central1
```

---

## Q5. How do you use Secret Manager with GKE?

```bash
# Create secret
echo -n "my-db-password" | gcloud secrets create db-password --data-file=-

# Access via Workload Identity (best practice)
# No additional setup if pod has secretmanager.secretAccessor IAM role

# In app code (Python):
# from google.cloud import secretmanager
# client = secretmanager.SecretManagerServiceClient()
# secret = client.access_secret_version(name="projects/myproject/secrets/db-password/versions/latest")
# password = secret.payload.data.decode()

# Mount as file using Secret Store CSI (Kubernetes-native)
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: gcp-secrets
spec:
  provider: gcp
  parameters:
    secrets: |
      - resourceName: "projects/123456/secrets/db-password/versions/latest"
        path: "db-password"
  secretObjects:
  - secretName: app-secrets
    type: Opaque
    data:
    - objectName: db-password
      key: DB_PASSWORD
```

---

## Q6. How do you monitor GKE with Google Cloud Monitoring?

```bash
# Cloud Monitoring auto-collects from GKE (Container Insights)
# Access: console.cloud.google.com/monitoring

# Custom dashboard with Monitoring Query Language (MQL):
fetch k8s_container
| metric 'kubernetes.io/container/cpu/request_utilization'
| filter resource.cluster_name == 'my-cluster'
| filter resource.namespace_name == 'production'
| align mean_aligner()
| every 1m
| group_by [resource.pod_name], [mean_cpu: mean(value.request_utilization)]
| condition mean_cpu > 0.8

# Alert on pod CPU > 80%
gcloud alpha monitoring policies create \
  --notification-channels my-slack-channel \
  --display-name "High CPU" \
  --condition-display-name "Pod CPU > 80%" \
  --condition-filter 'resource.type="k8s_container" AND metric.type="kubernetes.io/container/cpu/request_utilization"' \
  --condition-threshold-value 0.8 \
  --condition-threshold-comparison COMPARISON_GT

# Log-based metrics (Ops-specific):
# Create metric from log entries (e.g., count 500 errors)
gcloud logging metrics create error-count \
  --description "HTTP 500 errors" \
  --log-filter 'resource.type="k8s_container" AND textPayload:"HTTP 500"'
```

---

## Q7. What is Binary Authorization and how does it enforce supply chain security?

```bash
# Binary Authorization: require container images to be attested before deploying
# Only signed, verified images can run on GKE

# Enable on cluster
gcloud container clusters update my-cluster \
  --enable-binauthz \
  --region us-central1

# Create attestor (who can sign images)
gcloud container binauthz attestors create ci-attestor \
  --attestation-authority-note my-signing-note \
  --attestation-authority-note-project my-project

# Create policy: require attestation from CI
gcloud container binauthz policy import policy.yaml
# policy.yaml:
# admissionWhitelistPatterns:
# - namePattern: gcr.io/google_containers/*  # Allow GKE system images
# clusterAdmissionRules:
#   us-central1.my-cluster:
#     evaluationMode: REQUIRE_ATTESTATION
#     requireAttestationsBy:
#     - projects/my-project/attestors/ci-attestor

# In Cloud Build: sign image after security scan passes
gcloud container binauthz attestations create \
  --artifact-url gcr.io/myproject/myapp@sha256:abc123 \
  --attestor ci-attestor \
  --signature-file signature.pgp \
  --pgp-key-fingerprint my-key-fingerprint
```

---

## Q8. How do you implement VPC-native networking on GKE?

```bash
# VPC-native: pods get IPs from VPC (vs routes-based networking)
# Required for private GKE, Alias IPs

gcloud container clusters create my-cluster \
  --region us-central1 \
  --network my-vpc \
  --subnetwork my-subnet \
  --enable-ip-alias \                   # VPC-native
  --cluster-ipv4-cidr 10.100.0.0/16 \  # Pod CIDR
  --services-ipv4-cidr 10.101.0.0/20   # Service CIDR

# Private cluster (nodes have no public IPs)
gcloud container clusters create my-cluster \
  --region us-central1 \
  --enable-private-nodes \
  --master-ipv4-cidr 172.16.0.0/28 \   # Control plane IP range
  --enable-private-endpoint             # Control plane accessible only via VPC

# Network Policy (requires Calico or Dataplane V2)
gcloud container clusters create my-cluster \
  --enable-dataplane-v2 \              # Cilium-based, eBPF
  --enable-network-policy              # Enables NetworkPolicy resources
```

---

## Q9. What is Anthos and when would you use it?

```
Anthos: GCP's managed multi-cloud/hybrid Kubernetes platform
  - Run GKE on AWS, Azure, on-premises
  - Unified management console
  - Same Config Sync (GitOps) across all clusters
  - Service Mesh (Anthos Service Mesh = managed Istio)
  - Policy controller (OPA Gatekeeper as managed service)

Use cases:
  - Regulatory: some data must stay on-premises
  - Multi-cloud: reduce vendor lock-in
  - Migration: gradually move from on-prem to cloud
  - Hybrid: burst to cloud from on-prem

Components:
  Anthos Config Management: GitOps (Flux-based) across all clusters
  Anthos Service Mesh: Istio-based traffic management, mTLS
  Anthos clusters: GKE on other clouds/on-prem
  Cloud Run for Anthos: serverless on any cluster
```

---

## Q10. How do you perform zero-downtime upgrades on GKE?

```bash
# Node pool upgrade strategies

# 1. Surge upgrades (default) — gradual replacement
gcloud container node-pools update default-pool \
  --cluster my-cluster \
  --region us-central1 \
  --max-surge-upgrade 1 \    # Create 1 new node before deleting old
  --max-unavailable-upgrade 0  # Never have fewer nodes than desired

# 2. Blue-green node pool upgrade
# Create new node pool with new K8s version
gcloud container node-pools create new-pool \
  --cluster my-cluster \
  --region us-central1 \
  --node-version 1.29 \
  --num-nodes 3

# Cordon old pool (no new scheduling)
for node in $(kubectl get nodes -l cloud.google.com/gke-nodepool=old-pool -o name); do
  kubectl cordon $node
done

# Drain old pool (moves workloads to new pool)
for node in $(kubectl get nodes -l cloud.google.com/gke-nodepool=old-pool -o name); do
  kubectl drain $node --ignore-daemonsets --delete-emissary-data
done

# Delete old pool
gcloud container node-pools delete old-pool \
  --cluster my-cluster \
  --region us-central1

# 3. Enable auto-upgrade with maintenance windows
gcloud container clusters update my-cluster \
  --enable-autoupgrade \
  --maintenance-window-start 2000-01-01T02:00:00Z \  # 2 AM UTC
  --maintenance-window-end 2000-01-01T06:00:00Z \    # 6 AM UTC
  --maintenance-window-recurrence "FREQ=WEEKLY;BYDAY=SA,SU"
```

---

## Q11. How do you set up Cloud Armor (WAF) for GKE?

```bash
# Cloud Armor = GCP WAF, protects GKE via Cloud Load Balancing

# Create security policy
gcloud compute security-policies create my-waf-policy \
  --description "WAF policy for production"

# Add rule: block known malicious IPs
gcloud compute security-policies rules create 1000 \
  --security-policy my-waf-policy \
  --expression "inIpRange(origin.ip, '198.51.100.0/24')" \
  --action deny-403

# Enable OWASP Top 10 preconfigured rules
gcloud compute security-policies rules create 2000 \
  --security-policy my-waf-policy \
  --expression "evaluatePreconfiguredExpr('sqli-v33-stable')" \
  --action deny-403

gcloud compute security-policies rules create 2001 \
  --security-policy my-waf-policy \
  --expression "evaluatePreconfiguredExpr('xss-v33-stable')" \
  --action deny-403

# Rate limiting
gcloud compute security-policies rules create 3000 \
  --security-policy my-waf-policy \
  --expression "true" \
  --action rate-based-ban \
  --rate-limit-threshold-count 100 \
  --rate-limit-threshold-interval-sec 60

# Attach to backend service (GKE Ingress)
gcloud compute backend-services update my-backend \
  --security-policy my-waf-policy \
  --global
```

---

## Q12. Explain GCP IAM roles relevant to DevOps.

```bash
# Container/GKE roles:
roles/container.admin          # Full GKE management
roles/container.developer      # Deploy workloads, no cluster management
roles/container.viewer         # Read-only cluster access
roles/container.clusterViewer  # Get cluster credentials (for kubectl)

# Artifact Registry:
roles/artifactregistry.admin   # Full access
roles/artifactregistry.writer  # Push images (CI/CD)
roles/artifactregistry.reader  # Pull images (workloads)

# CI/CD service account needs:
gcloud projects add-iam-policy-binding my-project \
  --member "serviceAccount:cicd-sa@my-project.iam.gserviceaccount.com" \
  --role roles/container.developer
gcloud projects add-iam-policy-binding my-project \
  --member "serviceAccount:cicd-sa@my-project.iam.gserviceaccount.com" \
  --role roles/artifactregistry.writer
gcloud projects add-iam-policy-binding my-project \
  --member "serviceAccount:cicd-sa@my-project.iam.gserviceaccount.com" \
  --role roles/secretmanager.secretAccessor

# Least privilege: grant on specific resource, not project
gcloud artifacts repositories add-iam-policy-binding my-repo \
  --location us-central1 \
  --member "serviceAccount:cicd-sa@my-project.iam.gserviceaccount.com" \
  --role roles/artifactregistry.writer
```

---

## Q13. What is Dataplane V2 and why should you use it?

```
Dataplane V2 = eBPF-based networking for GKE (powered by Cilium)

Benefits vs traditional kube-proxy + iptables:
  Performance: eBPF bypasses kernel network stack (50% less CPU)
  Security: L7 network policies, DNS-based policies
  Observability: built-in network metrics per connection
  Scale: iptables doesn't scale (O(n) rules), eBPF is O(1)

Enable:
gcloud container clusters create my-cluster \
  --dataplane-v2

Features enabled:
  NetworkPolicy enforcement (Cilium)
  Hubble (network observability)
  L7 HTTP network policies
  Bandwidth manager

Hubble UI (network traffic visualization):
kubectl port-forward -n kube-system svc/hubble-ui 12000:80
# Visualize all pod-to-pod traffic in real time
```

---

## Q14. How do you implement cost controls in GCP for Kubernetes?

```bash
# 1. GKE cost allocation labels
kubectl label namespace production team=backend cost-center=eng-001

# 2. Resource quotas (prevent runaway costs)
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ResourceQuota
metadata:
  name: production-quota
  namespace: production
spec:
  hard:
    requests.cpu: "50"
    requests.memory: "100Gi"
    limits.cpu: "100"
    limits.memory: "200Gi"
EOF

# 3. GKE Autopilot (pay per pod, not per node)
gcloud container clusters create-auto my-cluster --region us-central1

# 4. Committed Use Discounts
gcloud billing commitments create \
  --billing-account my-billing-account \
  --plan 12-month \
  --region us-central1 \
  --type memory --amount 100 --unit GB

# 5. Budget alerts
gcloud billing budgets create \
  --billing-account my-billing \
  --display-name "GKE Budget" \
  --budget-amount 5000USD \
  --threshold-rule percent=50 \
  --threshold-rule percent=90 \
  --threshold-rule percent=100

# 6. Preemptible/Spot node pools (80% discount)
gcloud container node-pools create preemptible-pool \
  --cluster my-cluster \
  --preemptible \
  --num-nodes 5 \
  --machine-type e2-standard-4
```

---

## Q15. Describe a GCP outage you'd investigate with these symptoms: pods evicted, nodes NotReady.

```bash
# Step 1: Check node status
kubectl get nodes
gcloud compute instances list --filter="tags.items=gke-my-cluster"

# Step 2: Check why nodes are NotReady
kubectl describe node unhealthy-node | grep -A10 "Conditions"
# Common: MemoryPressure, DiskPressure, NodeNotReady

# Step 3: Check GKE cluster events
gcloud container operations list --filter="targetLink ~ my-cluster"

# Step 4: Node-level investigation (GCP SSH)
gcloud compute ssh my-node --zone us-central1-a -- \
  "sudo journalctl -u kubelet -n 100"

# Step 5: Check for resource exhaustion (Autopilot: auto-scales, Standard: check)
gcloud compute disks list | grep my-cluster

# Common GCP-specific causes:
# "Disk quota exceeded" → Artifact Registry pulling images filling disk
#   → Clean up: docker system prune on nodes, increase disk size
# "Network quota exceeded" → Too many load balancers/VPCs
#   → Check quotas: gcloud compute project-info describe | grep quotas
# "Preemptible node terminated" → Spot node eviction
#   → Normal behavior, check PDB protects workloads

# Preemptible node handling:
# PodDisruptionBudget protects against simultaneous eviction
# Graceful handling: terminationGracePeriodSeconds: 25 (before 30s SIGKILL)
```
