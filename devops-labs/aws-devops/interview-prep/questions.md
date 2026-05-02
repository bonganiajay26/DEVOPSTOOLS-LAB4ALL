# AWS DevOps Interview Questions

## Q1. Explain IRSA (IAM Roles for Service Accounts). Why is it better than instance profiles?

**Instance Profile** (old way):
- IAM role attached to EC2 node
- ALL pods on that node inherit node's permissions
- One compromised pod = access to all AWS services the node can access

**IRSA** (modern way):
- Each K8s ServiceAccount linked to a specific IAM Role
- Pod gets temporary credentials via OIDC federation
- Granular: each microservice has its own IAM role with minimal permissions

```bash
# Create IRSA
eksctl create iamserviceaccount \
  --cluster my-cluster \
  --namespace production \
  --name api-service-sa \
  --attach-policy-arn arn:aws:iam::123456789:policy/api-s3-policy \
  --approve

# This creates:
# 1. Kubernetes ServiceAccount with annotation
# 2. IAM Role with OIDC trust policy
# 3. Policy attachment

# The pod gets AWS credentials from the EKS-provided OIDC token
# Token lives at: /var/run/secrets/eks.amazonaws.com/serviceaccount/token
```

---

## Q2. What is the difference between ECS and EKS?

| | ECS | EKS |
|-|-----|-----|
| Orchestration | AWS-native | Kubernetes |
| Learning curve | Low | High |
| Ecosystem | AWS-only | K8s ecosystem |
| Multi-cloud | No | Yes |
| Control plane | Fully managed | Managed (AWS maintains) |
| Cost | Free control plane | $0.10/hour control plane |
| Best for | AWS-only, simple apps | Complex apps, K8s skills |

---

## Q3. How do you set up a multi-account AWS DevOps strategy?

```
Account structure:
  Management (root) account
    └── Development account    → developers deploy freely
    └── Staging account        → pre-production testing
    └── Production account     → live traffic
    └── Shared Services account → ECR, artifact storage, logging

Benefits:
  - Blast radius: production incident can't affect dev
  - Billing: clear cost allocation per environment
  - Security: strict production access controls

Cross-account deployment:
  CI/CD in Shared Services account
  → Assumes role in Production account → deploys to EKS
  
IAM role trust policy in Production:
{
  "Principal": {
    "AWS": "arn:aws:iam::SHARED_ACCOUNT:role/cicd-deployer"
  },
  "Action": "sts:AssumeRole"
}
```

---

## Q4. How do you secure an EKS cluster?

```bash
# 1. Private endpoint (control plane not internet-accessible)
aws eks update-cluster-config \
  --name my-cluster \
  --resources-vpc-config endpointPublicAccess=false,endpointPrivateAccess=true

# 2. Enable envelope encryption for etcd secrets
aws eks create-cluster \
  --encryption-config resources=secrets,provider.keyArn=arn:aws:kms:...

# 3. Enable audit logging
aws eks update-cluster-config \
  --name my-cluster \
  --logging '{"clusterLogging":[{"types":["audit","api","authenticator"],"enabled":true}]}'

# 4. Use IAM Authenticator for access control
# Map IAM roles/users to K8s RBAC groups

# 5. Enable security groups for pods (instead of node-level SGs)
kubectl set env daemonset aws-node -n kube-system ENABLE_POD_ENI=true

# 6. Use EKS-managed node groups with SSM (no SSH)
# No bastion host needed, audited access via SSM Session Manager

# 7. Enable Secrets Store CSI Driver + AWS Secrets Manager
# Mount secrets from Secrets Manager directly into pods
```

---

## Q5. Describe your experience with AWS Cost Optimization for EKS.

```
Strategy 1: Right-size nodes (Karpenter)
  Karpenter replaces Cluster Autoscaler
  Provisions exact instance type for workload
  Consolidates underutilized nodes

Strategy 2: Spot instances for stateless workloads
  70-90% savings vs On-Demand
  Use multiple instance types for availability
  Graceful handling of 2-minute termination notice

Strategy 3: Savings Plans / Reserved Instances
  1-year commit on baseline capacity = 40% savings
  Spot for burst above baseline

Strategy 4: Scale to zero (KEDA)
  Dev/staging clusters: scale to 0 at night
  Cron-based: 0 replicas 6pm-8am, scale up at 8am

Strategy 5: Resource quotas and LimitRanges
  Prevent over-provisioning
  Teams responsible for their namespace costs

Strategy 6: Optimize images
  Smaller images = faster pull = less bandwidth cost
  ECR Lifecycle policies: delete old images

Typical savings: 40-60% vs un-optimized setup
```

---

## Q6. How does CodePipeline integrate with EKS?

```yaml
# buildspec.yml for CodeBuild deploy stage
version: 0.2
phases:
  install:
    commands:
    - curl -LO https://dl.k8s.io/release/v1.29.0/bin/linux/amd64/kubectl
    - chmod +x kubectl && mv kubectl /usr/local/bin/
  build:
    commands:
    # Authenticate to EKS
    - aws eks update-kubeconfig --name $EKS_CLUSTER --region $AWS_REGION
    
    # Update image in deployment
    - IMAGE_TAG=$(cat imagedefinitions.json | jq -r '.[0].imageUri' | cut -d: -f2)
    - kubectl set image deployment/myapp app=$ECR_URI:$IMAGE_TAG -n production
    
    # Wait for rollout
    - kubectl rollout status deployment/myapp -n production --timeout=10m
    
    # Smoke test
    - sleep 10
    - curl -sf https://api.company.com/health
env:
  variables:
    EKS_CLUSTER: my-cluster
    AWS_REGION: us-east-1
```

---

## Q7. What are AWS Systems Manager Parameter Store vs Secrets Manager?

```
Parameter Store:
  - Free for Standard (up to 4KB) and Advanced ($0.05/param/month)
  - Encrypted with KMS (SecureString type) or plain (String/StringList)
  - Hierarchical naming: /myapp/production/database-url
  - Version history
  - Best for: config values, feature flags, connection strings

Secrets Manager:
  - $0.40/secret/month
  - Automatic rotation (built-in for RDS, custom Lambda)
  - Cross-account access
  - Fine-grained access policies
  - Best for: database passwords, API keys needing rotation

# Access in EKS with External Secrets Operator:
# Parameter Store:
spec:
  data:
  - secretKey: db-url
    remoteRef:
      key: /myapp/production/database-url  # Parameter path

# Secrets Manager:
spec:
  data:
  - secretKey: api-key
    remoteRef:
      key: prod/myapp/stripe-api-key       # Secret name
      property: api_key                    # JSON key within secret
```

---

## Q8. How do you implement blue/green deployments on AWS EKS?

```bash
# Option 1: Kubernetes-native (Service selector swap)
kubectl patch service myapp-svc \
  -p '{"spec":{"selector":{"version":"green"}}}'

# Option 2: AWS ALB with weighted routing
kubectl annotate service myapp-green \
  "alb.ingress.kubernetes.io/actions.forward-action": |
  {
    "type": "forward",
    "forwardConfig": {
      "targetGroups": [
        {"serviceName": "myapp-blue", "servicePort": 80, "weight": 90},
        {"serviceName": "myapp-green", "servicePort": 80, "weight": 10}
      ]
    }
  }

# Option 3: Route53 weighted routing
# Blue: weight 255 (100%), Green: weight 0
# Gradually shift: 90/10, 50/50, 0/100

# Option 4: AWS App Mesh (service mesh)
# VirtualRouter with weighted routes
```

---

## Q9. How do you troubleshoot a pod that can't access S3?

```bash
# 1. Check the error
kubectl logs mypod | grep -i "access denied\|no credentials\|s3"

# 2. Verify ServiceAccount annotation
kubectl get sa my-sa -n production -o yaml | grep eks.amazonaws.com

# 3. Check IAM role exists
aws iam get-role --role-name my-irsa-role

# 4. Verify trust policy includes correct OIDC provider
aws iam get-role --role-name my-irsa-role | jq '.Role.AssumeRolePolicyDocument'

# 5. Check environment variables in pod
kubectl exec my-pod -- env | grep AWS
# Should see: AWS_WEB_IDENTITY_TOKEN_FILE, AWS_ROLE_ARN

# 6. Test AWS CLI inside pod
kubectl exec -it my-pod -- aws sts get-caller-identity
# Should show the IRSA role, not the node role

# 7. Verify S3 bucket policy allows the role
aws s3api get-bucket-policy --bucket my-bucket

# Common issue: OIDC provider thumbprint mismatch
aws eks describe-cluster --name my-cluster | jq '.cluster.identity'
aws iam list-open-id-connect-providers
```

---

## Q10. What is AWS CDK and how does it compare to CloudFormation and Terraform?

```python
# AWS CDK — write infrastructure in Python/TypeScript/Go
from aws_cdk import Stack, aws_eks as eks, aws_ec2 as ec2
from constructs import Construct

class EksStack(Stack):
    def __init__(self, scope: Construct, id: str, **kwargs):
        super().__init__(scope, id, **kwargs)

        vpc = ec2.Vpc(self, "EksVpc", max_azs=3)
        
        cluster = eks.Cluster(self, "MyCluster",
            cluster_name="my-cluster",
            version=eks.KubernetesVersion.V1_29,
            vpc=vpc,
            default_capacity=0  # Manage node groups separately
        )
        
        cluster.add_nodegroup_capacity("standard",
            instance_types=[ec2.InstanceType("m5.xlarge")],
            desired_size=3,
            min_size=3,
            max_size=20
        )

# CDK synth → generates CloudFormation
# CDK deploy → deploys via CloudFormation

# Comparison:
# CloudFormation: AWS-only, verbose YAML, no code abstraction
# Terraform: Multi-cloud, HCL, huge ecosystem, better state management
# CDK: AWS-only, real programming language, high-level constructs, synthesizes to CFN
```

---

## Q11. How do you implement least-privilege IAM for EKS workloads?

```json
// Minimal S3 read policy for a specific bucket and prefix
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::my-data-bucket/myapp/*",
        "arn:aws:s3:::my-data-bucket"
      ],
      "Condition": {
        "StringEquals": {
          "s3:prefix": ["myapp/"]
        }
      }
    }
  ]
}

// Minimal Secrets Manager policy
{
  "Statement": [{
    "Effect": "Allow",
    "Action": ["secretsmanager:GetSecretValue"],
    "Resource": ["arn:aws:secretsmanager:us-east-1:123456789:secret:prod/myapp/*"]
  }]
}
```

---

## Q12. Explain VPC design for EKS production workloads.

```
VPC: 10.0.0.0/16 (65,536 IPs)

Subnets per AZ (3 AZs):
  Public:   10.0.0.0/20   (4,096 IPs each) — ALBs, NAT GWs
  Private:  10.0.16.0/20  (4,096 IPs each) — EKS nodes
  Database: 10.0.32.0/24  (256 IPs each)   — RDS, ElastiCache

EKS networking:
  Nodes in private subnets (no public IPs)
  ALB in public subnets
  Traffic: Internet → ALB → Node Port → Pod

Node CIDR vs Pod CIDR:
  AWS VPC CNI: pods get VPC IPs (no overlay)
  Each pod = one ENI secondary IP
  Plan: large enough subnets for max pod count
  m5.xlarge = max 58 pods = needs 58 IPs per node

Security Groups:
  Cluster SG: nodes talk to control plane
  Node SG: allow pod traffic, deny direct internet
  ALB SG: 80/443 from internet, forward to nodes
```

---

## Q13. How do you handle database migrations in AWS with zero downtime?

```bash
# Schema changes that are backward compatible:
# 1. Deploy migration (adds new column, default value)
# 2. Deploy app v2 (uses new column)
# 3. (Later) Remove old column

# For RDS:
# Use AWS DMS for live data migration
# Blue-green deployments in RDS (Aurora supports this natively)

# In EKS Helm chart, hook for migrations:
# helm.sh/hook: pre-upgrade  → CodeBuild step runs migration

# For Aurora:
# - Point-in-time recovery if migration fails
# - Read replica for testing migration safely
# - Multi-AZ for HA during migration

# Track migration state:
aws rds describe-db-instances --query 'DBInstances[].DBInstanceStatus'
# Available → Modifying → Available
```

---

## Q14. What is AWS X-Ray and how do you integrate it with EKS?

```yaml
# AWS X-Ray — distributed tracing service
# SDK instruments your app, X-Ray daemon forwards traces to AWS

# Deploy X-Ray daemon as DaemonSet
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: xray-daemon
spec:
  template:
    spec:
      containers:
      - name: xray-daemon
        image: amazon/aws-xray-daemon
        ports:
        - containerPort: 2000
          protocol: UDP
        env:
        - name: AWS_REGION
          value: us-east-1
      serviceAccountName: xray-daemon-sa  # Needs IRSA with xray:PutTraceSegments

# In app (Python example):
from aws_xray_sdk.core import xray_recorder, patch_all
patch_all()  # Auto-instrument boto3, requests, SQLAlchemy
xray_recorder.configure(service='my-api', daemon_address='xray-daemon:2000')
```

---

## Q15. How do you implement GitOps-style deployments with AWS CodePipeline?

```
Repo structure:
  app-repo/          → application code + Dockerfile
  infra-repo/        → K8s manifests (GitOps repo)

Pipeline:
  1. Push to app-repo main
  2. CodePipeline triggers
  3. CodeBuild: test + build image + push to ECR
  4. CodeBuild: clone infra-repo, update image tag
     git commit -m "chore: update myapp to $IMAGE_TAG"
     git push
  5. ArgoCD watches infra-repo → deploys to EKS

Why this is better than direct kubectl in CodePipeline:
  ✅ Git is source of truth (not pipeline state)
  ✅ Rollback = git revert
  ✅ All changes auditable in Git
  ✅ Drift detection (ArgoCD self-heal)
  ✅ No K8s credentials in CodePipeline
```
