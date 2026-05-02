# Lab 01: Terraform Getting Started — Local State and AWS S3

**Difficulty**: Beginner | **Time**: 45 minutes  
**Goal**: Learn Terraform workflow end-to-end: init → plan → apply → destroy. Provision real AWS resources.

---

## Prerequisites

```bash
# Install Terraform
brew install terraform    # macOS
# Or: https://developer.hashicorp.com/terraform/install

terraform version

# AWS CLI
aws configure   # Enter Access Key, Secret Key, Region
aws sts get-caller-identity   # Verify identity
```

---

## Part 1: Your First Terraform Configuration

```bash
mkdir terraform-lab && cd terraform-lab

cat > main.tf << 'EOF'
# Terraform configuration block — specify providers
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Configure the AWS provider
provider "aws" {
  region = "us-east-1"

  # Default tags applied to all resources
  default_tags {
    tags = {
      Environment = "lab"
      ManagedBy   = "terraform"
      Project     = "terraform-lab"
    }
  }
}

# Create an S3 bucket
resource "aws_s3_bucket" "lab" {
  bucket = "terraform-lab-${random_id.suffix.hex}"

  lifecycle {
    prevent_destroy = false   # Allow destroy for lab
  }
}

# Random suffix to make bucket name unique
resource "random_id" "suffix" {
  byte_length = 4
}

# Enable versioning
resource "aws_s3_bucket_versioning" "lab" {
  bucket = aws_s3_bucket.lab.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Block all public access
resource "aws_s3_bucket_public_access_block" "lab" {
  bucket                  = aws_s3_bucket.lab.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Output the bucket name
output "bucket_name" {
  value       = aws_s3_bucket.lab.bucket
  description = "The S3 bucket name"
}

output "bucket_arn" {
  value = aws_s3_bucket.lab.arn
}
EOF

# Add random provider to versions
cat >> main.tf << 'EOF'

# We also need the random provider for random_id
# Add it to required_providers above:
# random = { source = "hashicorp/random", version = "~> 3.0" }
EOF
```

### Step 2: Initialize and Plan

```bash
# Step 1: Initialize (download providers)
terraform init

# Step 2: Preview changes (dry run — NO AWS API calls)
terraform plan

# The plan shows:
# + create  aws_s3_bucket.lab
# + create  aws_s3_bucket_public_access_block.lab
# + create  aws_s3_bucket_versioning.lab
# + create  random_id.suffix
#
# Plan: 4 to add, 0 to change, 0 to destroy.

# Step 3: Validate syntax
terraform validate
```

### Step 3: Apply

```bash
# Apply the plan
terraform apply

# Review the plan again, type "yes" to confirm

# Outputs:
# bucket_name = "terraform-lab-a1b2c3d4"
# bucket_arn  = "arn:aws:s3:::terraform-lab-a1b2c3d4"

# Verify in AWS
aws s3 ls | grep terraform-lab

# Explore the state file
cat terraform.tfstate | python3 -m json.tool | head -50
```

---

## Part 2: Modify Infrastructure

```bash
# Add an IAM user with S3 access
cat >> main.tf << 'EOF'

# IAM user for S3 access
resource "aws_iam_user" "s3_user" {
  name = "s3-lab-user"
  path = "/lab/"
}

# IAM policy for S3 access
resource "aws_iam_policy" "s3_access" {
  name        = "s3-lab-access"
  description = "Access to the lab S3 bucket"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
      Resource = [
        aws_s3_bucket.lab.arn,
        "${aws_s3_bucket.lab.arn}/*"
      ]
    }]
  })
}

resource "aws_iam_user_policy_attachment" "s3_user" {
  user       = aws_iam_user.s3_user.name
  policy_arn = aws_iam_policy.s3_access.arn
}

output "iam_user_arn" {
  value = aws_iam_user.s3_user.arn
}
EOF

# Plan — shows only the new resources (existing resources untouched)
terraform plan
# Plan: 3 to add, 0 to change, 0 to destroy.

terraform apply -auto-approve
```

---

## Part 3: State Management

```bash
# List all resources in state
terraform state list

# Inspect a specific resource
terraform state show aws_s3_bucket.lab

# The state shows actual AWS resource attributes:
# id = "terraform-lab-a1b2c3d4"
# arn = "arn:aws:s3:::terraform-lab-a1b2c3d4"
# region = "us-east-1"

# Refresh state (sync with actual AWS state)
terraform refresh

# Simulate drift: manually change something in AWS console
# Then run plan to see Terraform detect the drift
terraform plan
# Shows the drift as a change to make
```

---

## Part 4: Variables and Outputs

```bash
# Create a variables file
cat > variables.tf << 'EOF'
variable "environment" {
  type        = string
  description = "Deployment environment"
  default     = "lab"

  validation {
    condition     = contains(["lab", "dev", "staging", "production"], var.environment)
    error_message = "Environment must be: lab, dev, staging, or production."
  }
}

variable "bucket_prefix" {
  type        = string
  description = "Prefix for the S3 bucket name"
  default     = "terraform-lab"
}

variable "enable_versioning" {
  type    = bool
  default = true
}
EOF

# Use variables in main.tf (update the resource)
# bucket = "${var.bucket_prefix}-${random_id.suffix.hex}"

# Run with variable override
terraform plan -var="environment=dev" -var="bucket_prefix=my-lab"

# Or create a tfvars file
cat > lab.tfvars << 'EOF'
environment       = "lab"
bucket_prefix     = "my-lab"
enable_versioning = true
EOF

terraform plan -var-file=lab.tfvars
```

---

## Part 5: Destroy

```bash
# Remove everything (reverse order of creation)
terraform destroy

# Type "yes" to confirm
# Terraform removes all resources it created

# Verify
aws s3 ls | grep terraform-lab
# Should be empty!

# Clean up local files
cd ..
rm -rf terraform-lab
```

---

## What You Learned

- [x] Terraform workflow: init → validate → plan → apply → destroy
- [x] Resource creation: S3, IAM
- [x] State file: what it stores, why it matters
- [x] Drift detection with `terraform plan`
- [x] Variables and validation
- [x] Outputs for consuming resource values

## Next Lab

→ [Lab 02: Remote State, Modules, and Multi-Environment Setup](lab-02-remote-state.md)
