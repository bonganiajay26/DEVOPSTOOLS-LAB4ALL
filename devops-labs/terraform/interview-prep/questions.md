# Terraform Interview Questions

## Q1. What is Terraform state and why does it matter?

State is a JSON file mapping Terraform resources to real cloud resources. Without it, Terraform can't know what already exists.

```bash
# State stores: resource IDs, metadata, dependency graph
terraform state list          # List all managed resources
terraform state show aws_eks_cluster.main  # Inspect specific resource

# Remote state backends (production requirement):
# S3 + DynamoDB (AWS), GCS (GCP), Azure Blob + Table (Azure), Terraform Cloud

# State locking prevents concurrent applies corrupting state
# DynamoDB table: terraform lock/unlock on every plan/apply
```

---

## Q2. What happens if you delete the Terraform state file?

Terraform loses awareness of existing resources. Next `plan` shows everything as "to create" again.

**Recovery:**
```bash
# Import existing resources back into state
terraform import aws_s3_bucket.my-bucket my-existing-bucket-name
terraform import aws_eks_cluster.main my-cluster-name

# For complex setups: use terraformer to auto-import
terraformer import aws --resources=eks,vpc,rds --regions=us-east-1
```

---

## Q3. Explain the difference between `terraform taint` (deprecated) / `replace` and `destroy`.

```bash
# terraform apply -replace: destroys and recreates ONE resource
# Use when resource is in bad state but others are fine
terraform apply -replace=aws_instance.web

# terraform destroy: destroys EVERYTHING in the state
# Use to tear down entire environment

# terraform destroy -target: destroy specific resource
terraform destroy -target=aws_rds_instance.database
```

---

## Q4. How do you handle Terraform in a team? What problems arise?

**Problems:**
- Concurrent applies → state corruption
- State stored in Git → conflicts, secrets exposed
- Different versions → state format incompatibility

**Solutions:**
```hcl
# Remote state + locking
backend "s3" {
  bucket         = "terraform-state"
  dynamodb_table = "terraform-lock"   # Prevents concurrent applies
}

# Version pinning
terraform {
  required_version = "~> 1.6.0"      # All team members same version
}

# Use Terraform Cloud for team features:
# - Remote execution, state management, PR integration, RBAC
```

---

## Q5. What is `terraform workspace` and when NOT to use it?

```bash
# Workspaces: separate state per workspace in same backend
terraform workspace new staging
terraform workspace select production
terraform workspace list

# Access in code:
resource "aws_eks_cluster" "main" {
  name = "cluster-${terraform.workspace}"
}
```

**When NOT to use**: For environment isolation. Workspaces share the same code — can accidentally apply staging code to prod.

**Better approach**: Separate directories per environment with separate state:
```
infrastructure/
  environments/
    production/   → own main.tf, own .tfstate
    staging/      → own main.tf, own .tfstate
  modules/
    eks/          → shared module
```

---

## Q6. How do you prevent accidental destruction of production resources?

```hcl
# 1. lifecycle prevent_destroy
resource "aws_rds_instance" "production" {
  lifecycle {
    prevent_destroy = true   # terraform destroy fails with clear error
  }
}

# 2. S3 bucket versioning + MFA delete for state bucket

# 3. Require plan review before apply (CI/CD)
# GitHub Actions: terraform plan on PR, terraform apply only on merge

# 4. Use -target for surgical changes
terraform apply -target=aws_deployment.app   # Only this resource

# 5. Terragrunt confirm-production plugin (requires typing "yes-i-am-in-production")
```

---

## Q7. How do you manage secrets in Terraform?

```hcl
# ❌ NEVER hardcode secrets
resource "aws_db_instance" "main" {
  password = "hardcoded-bad"
}

# ✅ Use random_password + store in Secrets Manager
resource "random_password" "db" {
  length  = 32
  special = true
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id     = aws_secretsmanager_secret.db.id
  secret_string = random_password.db.result
}

resource "aws_db_instance" "main" {
  password = random_password.db.result  # Still in state — state is encrypted
}

# ✅ Read from existing Secrets Manager
data "aws_secretsmanager_secret_version" "db" {
  secret_id = "prod/database/password"
}

# ✅ Environment variables for sensitive vars
# export TF_VAR_db_password="mypassword"
# Then use: var.db_password in code

# ✅ Use Vault provider
provider "vault" { address = "https://vault.company.com" }
data "vault_generic_secret" "db" { path = "secret/prod/database" }
```

---

## Q8. Explain `terraform plan` output. What does each symbol mean?

```
+ create         ← New resource
~ update         ← In-place update (no downtime usually)
- destroy        ← Will be deleted
-/+ replace      ← Destroy then create (potential downtime!)
<= read          ← Data source read

# Critical: watch for -/+ replace on:
# - EKS cluster (outage!)
# - RDS instance (data loss if not snapshotting!)
# - Security groups (can disconnect all traffic)

# Always read the plan carefully before apply in production
```

---

## Q9. What is the `depends_on` meta-argument?

```hcl
# Explicit dependency when Terraform can't infer it
resource "aws_iam_role_policy_attachment" "eks" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks.name
}

resource "aws_eks_cluster" "main" {
  name     = "my-cluster"
  role_arn = aws_iam_role.eks.arn

  # Terraform infers dependency on aws_iam_role.eks from role_arn reference
  # But we need to wait for the policy attachment too
  depends_on = [aws_iam_role_policy_attachment.eks]
}
```

---

## Q10. How do you refactor Terraform code without destroying resources?

```bash
# Move resource in state (renamed in code)
terraform state mv aws_instance.web aws_instance.web_server

# Move resource to module
terraform state mv aws_s3_bucket.logs module.logging.aws_s3_bucket.logs

# Remove from state (stops managing, doesn't destroy)
terraform state rm aws_s3_bucket.legacy

# Import resource from another state
terraform state pull > old-state.json
# Edit JSON to extract specific resources
terraform state push new-state.json
```

---

## Q11. What is Terragrunt and why would you use it?

Terragrunt is a thin Terraform wrapper that adds:
- DRY (Don't Repeat Yourself) configuration
- Auto-generate backend config per environment
- Module dependency management
- `run-all` for multi-module deployments

```hcl
# terragrunt.hcl — define once, use everywhere
remote_state {
  backend = "s3"
  config = {
    bucket = "terraform-state-${local.account_id}"
    key    = "${path_relative_to_include()}/terraform.tfstate"
    region = "us-east-1"
    dynamodb_table = "terraform-lock"
  }
}

# Include in child modules:
include "root" {
  path = find_in_parent_folders()
}
```

---

## Q12. How do you test Terraform code?

```bash
# 1. terraform validate — syntax/schema check
terraform validate

# 2. tflint — provider-specific linting
tflint --enable-plugin=aws

# 3. checkov — security scanning
checkov -d .
pip install checkov && checkov --directory .

# 4. terratest (Go-based integration tests)
func TestEKSCluster(t *testing.T) {
  opts := &terraform.Options{TerraformDir: "../modules/eks"}
  defer terraform.Destroy(t, opts)
  terraform.InitAndApply(t, opts)
  clusterName := terraform.Output(t, opts, "cluster_name")
  assert.Equal(t, "test-cluster", clusterName)
}

# 5. terraform-docs — auto-generate documentation
terraform-docs markdown table . > README.md
```

---

## Q13. A terraform apply fails halfway. What do you do?

```bash
# Terraform applies partial changes and updates state for succeeded resources
# Failed resources are NOT in state

# Check current state
terraform state list

# Fix the underlying issue, then re-run apply
terraform apply -var-file=prod.tfvars

# If state is inconsistent:
terraform refresh    # Sync state with actual reality

# If a resource was created outside Terraform during the partial apply:
terraform import aws_security_group.new sg-0123456789

# Don't panic: Terraform is designed for this — re-running apply is safe
```

---

## Q14. How do you structure Terraform for a large organization?

```
platform-infra/
├── modules/               # Reusable modules (versioned in separate repo)
│   ├── eks/
│   ├── rds/
│   └── vpc/
├── environments/
│   ├── production/
│   │   ├── eks/           # Calls modules with prod vars
│   │   ├── database/
│   │   └── vpc/
│   ├── staging/
│   └── dev/
├── global/
│   ├── iam/               # Cross-environment IAM roles
│   └── dns/               # Route53 zones
└── .github/workflows/
    └── terraform.yml      # Plan on PR, apply on merge
```

---

## Q15. What is the difference between `count` and `for_each`?

```hcl
# count: creates N instances, addressed by index
# Problem: insert/remove in middle → all subsequent resources get new index → re-create!

resource "aws_subnet" "private" {
  count      = 3
  cidr_block = "10.0.${count.index}.0/24"
}
# Addressed as: aws_subnet.private[0], [1], [2]
# Remove middle: aws_subnet.private[1] → [2] becomes new [1] → DESTROY AND RECREATE!

# for_each: creates instances from a map/set, addressed by key
# Stable addressing — removing one doesn't affect others
resource "aws_subnet" "private" {
  for_each   = { "a" = "10.0.1.0/24", "b" = "10.0.2.0/24", "c" = "10.0.3.0/24" }
  cidr_block = each.value
}
# Addressed as: aws_subnet.private["a"], ["b"], ["c"]
# Remove "b": only that one is destroyed, "a" and "c" untouched ✅

# Rule: Use for_each whenever resources have stable identifiers (not just indexes)
```
