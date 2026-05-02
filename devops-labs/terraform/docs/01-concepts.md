# Terraform Core Concepts

## How Terraform Works

```
1. Write HCL configuration (.tf files)
2. terraform init   → Downloads providers, modules
3. terraform plan   → Compares desired state (HCL) vs actual state (tfstate)
                     → Shows diff: create / update / destroy
4. terraform apply  → Makes API calls to create/update/delete resources
                     → Updates tfstate with new reality
```

## State File

The `.tfstate` file is Terraform's memory — it maps HCL resources to real cloud resources.

**NEVER:**
- Store state in Git (contains secrets, causes conflicts)
- Delete the state file
- Manually edit the state file

**ALWAYS:**
- Use remote state backend (S3 + DynamoDB, GCS, Terraform Cloud)
- Enable state locking (prevents concurrent applies)
- Back up state regularly

```hcl
# Remote state on AWS S3 + DynamoDB locking
terraform {
  backend "s3" {
    bucket         = "my-terraform-state-prod"
    key            = "clusters/prod/eks/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    kms_key_id     = "arn:aws:kms:us-east-1:123456789:key/abc-def"
    dynamodb_table = "terraform-state-lock"  # Prevents concurrent applies
  }
}
```

---

## Resource Lifecycle

```hcl
resource "aws_instance" "web" {
  ami           = "ami-0123456789"
  instance_type = "t3.medium"

  # Lifecycle rules
  lifecycle {
    create_before_destroy = true   # Zero-downtime replace
    prevent_destroy       = true   # Block terraform destroy (for prod DBs)
    ignore_changes        = [      # Don't update these even if config changes
      tags["LastModified"],
      user_data,
    ]
  }
}
```

---

## Variables & Outputs

```hcl
# variables.tf
variable "environment" {
  type        = string
  description = "Deployment environment"
  validation {
    condition     = contains(["dev", "staging", "production"], var.environment)
    error_message = "Must be dev, staging, or production."
  }
}

variable "instance_count" {
  type    = number
  default = 2
}

variable "tags" {
  type    = map(string)
  default = {}
}

# terraform.tfvars
environment    = "production"
instance_count = 5
tags = {
  Team        = "platform"
  CostCenter  = "engineering"
  ManagedBy   = "terraform"
}

# outputs.tf
output "cluster_endpoint" {
  value     = aws_eks_cluster.main.endpoint
  sensitive = false
  description = "EKS API server endpoint"
}

output "database_password" {
  value     = random_password.db.result
  sensitive = true   # Masked in terraform output
}
```

---

## Modules

Reusable, versioned infrastructure components.

```hcl
# Call a module
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "my-cluster"
  cluster_version = "1.29"
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnets
}

# Local module
module "vpc" {
  source = "./modules/vpc"
  cidr   = "10.0.0.0/16"
  azs    = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

# Module structure
modules/
  vpc/
    main.tf
    variables.tf
    outputs.tf
    README.md
```

---

## Data Sources (Read existing infrastructure)

```hcl
# Read existing VPC (created outside Terraform)
data "aws_vpc" "existing" {
  filter {
    name   = "tag:Name"
    values = ["production-vpc"]
  }
}

# Read latest Amazon Linux 2 AMI
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

# Use in resource
resource "aws_instance" "web" {
  ami  = data.aws_ami.amazon_linux.id
  vpc_security_group_ids = [data.aws_vpc.existing.default_security_group_id]
}
```

---

## Locals

```hcl
locals {
  common_tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    Project     = var.project_name
    Owner       = var.team
  }

  cluster_name = "${var.project_name}-${var.environment}-eks"
  is_prod      = var.environment == "production"
  node_count   = local.is_prod ? 5 : 2
}

resource "aws_eks_cluster" "main" {
  name = local.cluster_name
  tags = local.common_tags
}
```

---

## For_each and Count

```hcl
# count: create N identical resources
resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]
  tags = { Name = "private-${count.index + 1}" }
}

# for_each: create resources from a map/set (better for stable addressing)
variable "buckets" {
  default = {
    assets  = { region = "us-east-1", versioning = true  }
    backups = { region = "us-west-2", versioning = false }
  }
}

resource "aws_s3_bucket" "app" {
  for_each = var.buckets
  bucket   = "myapp-${each.key}-${var.environment}"
  # each.key = "assets" or "backups"
  # each.value = { region = ..., versioning = ... }
}
```
