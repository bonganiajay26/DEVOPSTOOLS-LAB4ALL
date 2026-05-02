# Terraform Advanced Patterns

## 1. Remote State with Locking

```hcl
# Shared backend for team collaboration
terraform {
  backend "s3" {
    bucket         = "my-terraform-state-prod"
    key            = "environments/production/eks/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    kms_key_id     = "arn:aws:kms:us-east-1:123456789:key/abc-def"
    dynamodb_table = "terraform-state-lock"
  }
}

# Create the state bucket with versioning (run once, bootstrap)
resource "aws_s3_bucket" "tfstate" {
  bucket = "my-terraform-state-prod"
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
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.tfstate.arn
    }
  }
}

resource "aws_dynamodb_table" "tflock" {
  name         = "terraform-state-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute {
    name = "LockID"
    type = "S"
  }
}
```

---

## 2. Module Development Pattern

```
modules/
  vpc/
    main.tf       # Resources
    variables.tf  # Input variables
    outputs.tf    # Output values
    versions.tf   # Provider + terraform version constraints
    README.md     # Usage documentation

# Module main.tf
resource "aws_vpc" "main" {
  cidr_block           = var.cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.common_tags, {
    Name = "${var.name}-vpc"
  })
}

# Module variables.tf
variable "cidr" {
  type        = string
  description = "VPC CIDR block"
  validation {
    condition     = can(cidrnetmask(var.cidr))
    error_message = "Must be valid CIDR notation."
  }
}

variable "common_tags" {
  type    = map(string)
  default = {}
}

# Module outputs.tf
output "vpc_id" {
  value       = aws_vpc.main.id
  description = "VPC ID"
}

output "vpc_cidr" {
  value = aws_vpc.main.cidr_block
}
```

---

## 3. Workspaces vs Directory-Per-Environment

```bash
# Pattern A: Workspaces (NOT recommended for env separation)
terraform workspace new staging
terraform workspace new production
# Risk: same code, shared resources, accidental cross-env changes

# Pattern B: Separate directories (RECOMMENDED)
environments/
  staging/
    main.tf → calls modules with staging vars
    terraform.tfvars
    backend.tf → staging state bucket/key
  production/
    main.tf → calls same modules with prod vars
    terraform.tfvars
    backend.tf → production state bucket/key

# Pattern C: Terragrunt (DRY config)
# environments/production/vpc/terragrunt.hcl
terraform {
  source = "../../../../modules/vpc"
}
inputs = {
  cidr = "10.0.0.0/16"
  name = "production"
}
# Terragrunt auto-generates backend config per path
```

---

## 4. Sensitive Variables and Secret Injection

```hcl
# Mark variable as sensitive (masked in logs)
variable "db_password" {
  type      = string
  sensitive = true
}

# Output marked sensitive (masked in terraform output)
output "database_url" {
  value     = "postgresql://admin:${var.db_password}@${aws_db_instance.main.endpoint}/mydb"
  sensitive = true
}

# Use Vault provider for secret retrieval
provider "vault" {
  address = "https://vault.company.com"
}

data "vault_generic_secret" "db" {
  path = "secret/production/database"
}

resource "aws_db_instance" "main" {
  password = data.vault_generic_secret.db.data["password"]
}

# Or use AWS Secrets Manager
data "aws_secretsmanager_secret_version" "db" {
  secret_id = "prod/database/password"
}

resource "aws_db_instance" "main" {
  password = jsondecode(data.aws_secretsmanager_secret_version.db.secret_string)["password"]
}
```

---

## 5. Dynamic Blocks

```hcl
# Create security group rules from a variable
variable "ingress_rules" {
  type = list(object({
    port        = number
    protocol    = string
    cidr        = string
    description = string
  }))
  default = [
    { port = 80,  protocol = "tcp", cidr = "0.0.0.0/0", description = "HTTP" },
    { port = 443, protocol = "tcp", cidr = "0.0.0.0/0", description = "HTTPS" },
    { port = 22,  protocol = "tcp", cidr = "10.0.0.0/8", description = "SSH from VPN" },
  ]
}

resource "aws_security_group" "app" {
  name   = "app-sg"
  vpc_id = var.vpc_id

  dynamic "ingress" {
    for_each = var.ingress_rules
    content {
      from_port   = ingress.value.port
      to_port     = ingress.value.port
      protocol    = ingress.value.protocol
      cidr_blocks = [ingress.value.cidr]
      description = ingress.value.description
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

---

## 6. Terraform Cloud / Enterprise

```hcl
# terraform.tf — use Terraform Cloud as backend
terraform {
  cloud {
    organization = "my-company"

    workspaces {
      name = "production-eks"
      # Or multiple workspaces:
      # tags = ["production", "eks"]
    }
  }
}

# Features of Terraform Cloud:
# - Remote state (no S3 bucket needed)
# - Remote execution (runs in TF Cloud, not local machine)
# - Sentinel policies (OPA-like policy as code)
# - Cost estimation (see cost before apply)
# - RBAC (who can plan vs apply)
# - VCS integration (auto-plan on PR, auto-apply on merge)
# - Private module registry
```

---

## 7. Atlantis (GitOps for Terraform)

```yaml
# atlantis.yaml — in repository root
version: 3
projects:
- name: production-eks
  dir: environments/production/eks
  workspace: default
  autoplan:
    enabled: true
    when_modified:
    - "**/*.tf"
    - "**/*.tfvars"
  apply_requirements:
  - approved      # Require PR approval
  - mergeable     # All checks must pass

# Workflow:
# 1. Engineer opens PR with Terraform changes
# 2. Atlantis runs: terraform plan (auto)
# 3. Atlantis comments plan on PR
# 4. Engineer reviews plan
# 5. Engineer comments: atlantis apply
# 6. Atlantis applies and updates PR
# 7. Merge PR
```
