# Production EKS Cluster on AWS
# Requirements:
#   terraform >= 1.6.0
#   aws provider ~> 5.0
#
# Usage:
#   terraform init
#   terraform plan -var-file=prod.tfvars
#   terraform apply -var-file=prod.tfvars

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }

  backend "s3" {
    bucket         = "my-terraform-state"
    key            = "prod/eks/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = var.environment
      ManagedBy   = "terraform"
      Project     = var.project
    }
  }
}

# ── Variables ─────────────────────────────────────────────────
variable "aws_region"        { default = "us-east-1" }
variable "environment"       { default = "production" }
variable "project"           { default = "myplatform" }
variable "cluster_version"   { default = "1.29" }
variable "node_instance_type" { default = "m5.xlarge" }
variable "node_min"          { default = 3 }
variable "node_max"          { default = 20 }
variable "node_desired"      { default = 5 }

locals {
  cluster_name = "${var.project}-${var.environment}"
  azs          = slice(data.aws_availability_zones.available.names, 0, 3)
}

# ── Data Sources ──────────────────────────────────────────────
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# ── VPC ───────────────────────────────────────────────────────
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${local.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = local.azs
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway     = true
  single_nat_gateway     = var.environment != "production"  # HA NAT in prod
  enable_dns_hostnames   = true
  enable_dns_support     = true

  # Required tags for EKS
  public_subnet_tags = {
    "kubernetes.io/role/elb"                      = 1
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"             = 1
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

# ── EKS Cluster ───────────────────────────────────────────────
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = local.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Endpoint: private only in production
  cluster_endpoint_public_access  = var.environment != "production"
  cluster_endpoint_private_access = true

  # Enable IRSA (IAM Roles for Service Accounts)
  enable_irsa = true

  # Cluster addons
  cluster_addons = {
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
    vpc-cni    = { most_recent = true }
    aws-ebs-csi-driver = { most_recent = true }
  }

  # Managed node groups
  eks_managed_node_groups = {
    # On-demand nodes for critical workloads
    critical = {
      name           = "critical"
      instance_types = [var.node_instance_type]
      capacity_type  = "ON_DEMAND"
      min_size       = var.node_min
      max_size       = var.node_max
      desired_size   = var.node_desired

      labels = {
        workload-type = "critical"
        node-pool     = "on-demand"
      }
    }

    # Spot nodes for batch/non-critical workloads
    spot = {
      name           = "spot"
      instance_types = ["m5.xlarge", "m5a.xlarge", "m4.xlarge"]
      capacity_type  = "SPOT"
      min_size       = 0
      max_size       = 50
      desired_size   = 2

      taints = [{
        key    = "spot"
        value  = "true"
        effect = "NO_SCHEDULE"
      }]

      labels = {
        workload-type = "batch"
        node-pool     = "spot"
      }
    }
  }

  # Access entries (replaces aws-auth ConfigMap)
  access_entries = {
    admin = {
      kubernetes_groups = []
      principal_arn     = "arn:aws:iam::123456789:role/admin-role"
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }
}

# ── Outputs ───────────────────────────────────────────────────
output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value     = module.eks.cluster_endpoint
  sensitive = false
}

output "configure_kubectl" {
  value = "aws eks --region ${var.aws_region} update-kubeconfig --name ${module.eks.cluster_name}"
}
