# Lab 02: Remote State, Modules, and Multi-Environment

**Difficulty**: Intermediate | **Time**: 60 minutes  
**Goal**: Set up team-friendly Terraform with remote state, DynamoDB locking, and reusable modules.

---

## Part 1: Bootstrap Remote State Infrastructure

```bash
mkdir terraform-remote-lab && cd terraform-remote-lab

# First: create the state bucket manually (chicken-and-egg problem)
# You can't store Terraform state for the thing that stores Terraform state in itself

cat > bootstrap/main.tf << 'EOF'
# This bootstrap is applied ONCE and then the local state is checked in or deleted
# DO NOT use remote state for bootstrap itself

provider "aws" { region = "us-east-1" }

variable "state_bucket_name" { default = "company-terraform-state" }

# S3 bucket for remote state
resource "aws_s3_bucket" "tfstate" {
  bucket = var.state_bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# DynamoDB table for state locking
resource "aws_dynamodb_table" "tflock" {
  name         = "terraform-state-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = { Purpose = "Terraform state locking" }
}

output "state_bucket"    { value = aws_s3_bucket.tfstate.bucket }
output "lock_table"      { value = aws_dynamodb_table.tflock.name }
output "backend_config" {
  value = <<-CONFIG
  terraform {
    backend "s3" {
      bucket         = "${aws_s3_bucket.tfstate.bucket}"
      region         = "us-east-1"
      encrypt        = true
      dynamodb_table = "${aws_dynamodb_table.tflock.name}"
      key            = "ENVIRONMENT/SERVICE/terraform.tfstate"
    }
  }
  CONFIG
}
EOF

cd bootstrap
terraform init && terraform apply
cd ..
```

---

## Part 2: Create a Reusable VPC Module

```bash
mkdir -p modules/vpc

cat > modules/vpc/variables.tf << 'EOF'
variable "name"    { type = string }
variable "cidr"    { type = string; default = "10.0.0.0/16" }
variable "azs"     { type = list(string) }
variable "private_subnets" { type = list(string) }
variable "public_subnets"  { type = list(string) }
variable "enable_nat_gateway"   { type = bool; default = true }
variable "single_nat_gateway"   { type = bool; default = false }
variable "tags" { type = map(string); default = {} }
EOF

cat > modules/vpc/main.tf << 'EOF'
# Use the community module internally
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = var.name
  cidr = var.cidr
  azs  = var.azs

  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets

  enable_nat_gateway   = var.enable_nat_gateway
  single_nat_gateway   = var.single_nat_gateway
  enable_dns_hostnames = true
  enable_dns_support   = true

  # EKS-required tags
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = var.tags
}
EOF

cat > modules/vpc/outputs.tf << 'EOF'
output "vpc_id"          { value = module.vpc.vpc_id }
output "vpc_cidr"        { value = module.vpc.vpc_cidr_block }
output "private_subnets" { value = module.vpc.private_subnets }
output "public_subnets"  { value = module.vpc.public_subnets }
output "nat_gateway_ips" { value = module.vpc.nat_public_ips }
EOF

cat > modules/vpc/versions.tf << 'EOF'
terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  required_version = ">= 1.6.0"
}
EOF
```

---

## Part 3: Multi-Environment Directory Structure

```bash
mkdir -p environments/{staging,production}

# Staging environment
cat > environments/staging/main.tf << 'EOF'
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  backend "s3" {
    bucket         = "company-terraform-state"
    key            = "staging/vpc/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Environment = "staging"
      ManagedBy   = "terraform"
    }
  }
}

module "vpc" {
  source = "../../modules/vpc"

  name = "staging-vpc"
  cidr = "10.1.0.0/16"
  azs  = ["us-east-1a", "us-east-1b"]

  private_subnets = ["10.1.1.0/24", "10.1.2.0/24"]
  public_subnets  = ["10.1.101.0/24", "10.1.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true    # Staging: save money with single NAT
}

variable "aws_region" { default = "us-east-1" }

output "vpc_id"          { value = module.vpc.vpc_id }
output "private_subnets" { value = module.vpc.private_subnets }
EOF

# Production environment (higher spec)
cat > environments/production/main.tf << 'EOF'
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  backend "s3" {
    bucket         = "company-terraform-state"
    key            = "production/vpc/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Environment = "production"
      ManagedBy   = "terraform"
    }
  }
}

module "vpc" {
  source = "../../modules/vpc"

  name = "production-vpc"
  cidr = "10.0.0.0/16"
  azs  = ["us-east-1a", "us-east-1b", "us-east-1c"]    # 3 AZs for HA

  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = false    # Production: HA with one NAT per AZ
}

variable "aws_region" { default = "us-east-1" }

output "vpc_id"          { value = module.vpc.vpc_id }
output "private_subnets" { value = module.vpc.private_subnets }
EOF
```

---

## Part 4: Deploy and Verify

```bash
# Deploy staging
cd environments/staging
terraform init
terraform plan
terraform apply -auto-approve

# Check state is stored remotely
aws s3 ls s3://company-terraform-state/staging/vpc/

# Deploy production
cd ../production
terraform init
terraform plan
terraform apply

# Share VPC ID between stacks (remote state data source)
cat >> environments/production/main.tf << 'EOF'

# Read outputs from another stack (remote state data source)
data "terraform_remote_state" "staging_vpc" {
  backend = "s3"
  config = {
    bucket = "company-terraform-state"
    key    = "staging/vpc/terraform.tfstate"
    region = "us-east-1"
  }
}

output "staging_vpc_id" {
  value = data.terraform_remote_state.staging_vpc.outputs.vpc_id
}
EOF

terraform apply -auto-approve
terraform output staging_vpc_id
```

---

## Cleanup

```bash
cd environments/staging && terraform destroy
cd ../production && terraform destroy
cd ../../bootstrap && terraform destroy
cd ../.. && rm -rf terraform-remote-lab
```

## What You Learned

- [x] Remote state in S3 with DynamoDB locking
- [x] Module creation with variables and outputs
- [x] Multi-environment directory structure
- [x] Environment-specific backend configuration
- [x] Remote state data sources (cross-stack references)
