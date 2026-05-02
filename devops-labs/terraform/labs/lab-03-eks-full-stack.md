# Lab 03: Full Stack on AWS — VPC + EKS + RDS + Secrets Manager

**Difficulty**: Advanced | **Time**: 90 minutes  
**Goal**: Provision a complete production-grade AWS stack with Terraform.

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  AWS Account                         │
│                                                      │
│  ┌──────────────────────────────────────────────┐   │
│  │              VPC (10.0.0.0/16)               │   │
│  │                                              │   │
│  │  Public Subnets         Private Subnets      │   │
│  │  ┌──────────────┐      ┌──────────────────┐  │   │
│  │  │   ALB        │      │   EKS Nodes      │  │   │
│  │  │   NAT GWs    │      │   RDS (Multi-AZ) │  │   │
│  │  └──────────────┘      └──────────────────┘  │   │
│  └──────────────────────────────────────────────┘   │
│                                                      │
│  ECR Registry    Secrets Manager    CloudWatch       │
└─────────────────────────────────────────────────────┘
```

---

## Part 1: Project Structure

```bash
mkdir full-stack-lab && cd full-stack-lab

# Structure
mkdir -p {modules/{vpc,eks,rds},environments/production}

cat > environments/production/main.tf << 'EOF'
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws        = { source = "hashicorp/aws",        version = "~> 5.0"  }
    kubernetes = { source = "hashicorp/kubernetes",  version = "~> 2.0"  }
    helm       = { source = "hashicorp/helm",        version = "~> 2.0"  }
    random     = { source = "hashicorp/random",      version = "~> 3.0"  }
  }

  backend "s3" {
    bucket         = "company-terraform-state"
    key            = "production/full-stack/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = local.common_tags
  }
}

# After EKS is created, configure K8s and Helm providers
data "aws_eks_cluster" "main"      { name = module.eks.cluster_name }
data "aws_eks_cluster_auth" "main" { name = module.eks.cluster_name }

provider "kubernetes" {
  host                   = data.aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.main.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.main.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.main.token
  }
}

locals {
  cluster_name = "production-eks"
  common_tags = {
    Environment = "production"
    Project     = var.project_name
    ManagedBy   = "terraform"
    Owner       = var.team
  }
}
EOF

cat > environments/production/variables.tf << 'EOF'
variable "aws_region"   { default = "us-east-1" }
variable "project_name" { default = "myplatform" }
variable "team"         { default = "platform-engineering" }
EOF
```

---

## Part 2: VPC Module

```bash
cat > environments/production/vpc.tf << 'EOF'
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "production-vpc"
  cidr = "10.0.0.0/16"
  azs  = ["us-east-1a", "us-east-1b", "us-east-1c"]

  private_subnets  = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets   = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
  database_subnets = ["10.0.201.0/24", "10.0.202.0/24", "10.0.203.0/24"]

  enable_nat_gateway     = true
  single_nat_gateway     = false
  enable_dns_hostnames   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                      = 1
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"             = 1
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}
EOF
```

---

## Part 3: EKS Module

```bash
cat > environments/production/eks.tf << 'EOF'
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = local.cluster_name
  cluster_version = "1.29"
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnets

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  enable_irsa = true

  cluster_addons = {
    coredns            = { most_recent = true }
    kube-proxy         = { most_recent = true }
    vpc-cni            = { most_recent = true }
    aws-ebs-csi-driver = { most_recent = true }
  }

  eks_managed_node_groups = {
    # General purpose on-demand
    general = {
      instance_types  = ["m5.xlarge"]
      capacity_type   = "ON_DEMAND"
      min_size        = 3
      max_size        = 20
      desired_size    = 5
      labels          = { workload = "general" }
    }

    # Cost-optimized spot for batch workloads
    spot = {
      instance_types  = ["m5.xlarge", "m5a.xlarge", "m4.xlarge"]
      capacity_type   = "SPOT"
      min_size        = 0
      max_size        = 50
      desired_size    = 2
      labels          = { workload = "batch" }
      taints = [{
        key    = "spot"
        value  = "true"
        effect = "NO_SCHEDULE"
      }]
    }
  }
}

# ECR repository for container images
resource "aws_ecr_repository" "app" {
  name                 = "myapp"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true    # Security scan every push
  }

  lifecycle_policy = <<POLICY
{
  "rules": [{
    "rulePriority": 1,
    "description": "Keep last 20 images",
    "selection": {
      "tagStatus": "any",
      "countType": "imageCountMoreThan",
      "countNumber": 20
    },
    "action": { "type": "expire" }
  }]
}
POLICY
}

output "cluster_name"     { value = module.eks.cluster_name }
output "cluster_endpoint" { value = module.eks.cluster_endpoint }
output "ecr_url"          { value = aws_ecr_repository.app.repository_url }
output "configure_kubectl" {
  value = "aws eks --region ${var.aws_region} update-kubeconfig --name ${module.eks.cluster_name}"
}
EOF
```

---

## Part 4: RDS + Secrets

```bash
cat > environments/production/database.tf << 'EOF'
resource "random_password" "db" {
  length  = 32
  special = false    # RDS has issues with some special chars
}

resource "aws_secretsmanager_secret" "db" {
  name = "production/myapp/database"
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = "appuser"
    password = random_password.db.result
    host     = aws_db_instance.main.address
    port     = 5432
    dbname   = "appdb"
  })
}

resource "aws_db_subnet_group" "main" {
  name       = "production-rds"
  subnet_ids = module.vpc.database_subnets
}

resource "aws_security_group" "rds" {
  name   = "production-rds-sg"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
    description     = "PostgreSQL from EKS nodes"
  }
}

resource "aws_db_instance" "main" {
  identifier = "production-postgres"

  engine         = "postgres"
  engine_version = "15.5"
  instance_class = "db.r6g.large"

  allocated_storage     = 100
  max_allocated_storage = 500
  storage_encrypted     = true
  storage_type          = "gp3"

  db_name  = "appdb"
  username = "appuser"
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = true

  backup_retention_period = 30
  backup_window           = "03:00-04:00"

  deletion_protection = true
  skip_final_snapshot = false
  final_snapshot_identifier = "production-postgres-final"

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [password]
  }
}

output "db_secret_arn" { value = aws_secretsmanager_secret.db.arn }
output "db_endpoint"   { value = aws_db_instance.main.address }
EOF
```

---

## Part 5: Deploy and Connect

```bash
cd environments/production

# Initialize and plan
terraform init
terraform plan -out=tfplan

# Review: shows ~30 resources to create
# Apply (takes ~20 minutes for EKS)
terraform apply tfplan

# Configure kubectl
$(terraform output -raw configure_kubectl)

# Verify cluster
kubectl get nodes

# Get DB secret
aws secretsmanager get-secret-value \
  --secret-id $(terraform output -raw db_secret_arn) \
  --query SecretString \
  --output text | python3 -m json.tool

# Deploy a test app using IRSA
# Create SA with ECR pull permissions
kubectl create sa app-sa
kubectl annotate sa app-sa \
  eks.amazonaws.com/role-arn=$(terraform output -raw iam_role_arn || echo "arn:aws:iam::ACCOUNT:role/app-role")
```

---

## Cleanup (Important — EKS is expensive!)

```bash
# Remove K8s resources first
kubectl delete all --all -n default

# Destroy Terraform resources
terraform destroy

# This takes ~20 minutes
# Type "yes" to confirm
```

## What You Learned

- [x] Full production AWS infrastructure with Terraform
- [x] Chained providers (AWS → EKS → Kubernetes/Helm)
- [x] ECR repository with lifecycle policies
- [x] RDS with Secrets Manager integration
- [x] IRSA for pod-level AWS permissions
- [x] Multi-AZ RDS with deletion protection
