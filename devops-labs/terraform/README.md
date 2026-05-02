# Terraform

> **Provision and manage cloud infrastructure as code. Write once, deploy anywhere.**

---

## Quick Navigation

| Section | Contents |
|---------|----------|
| [docs/01-concepts.md](docs/01-concepts.md) | HCL, state, providers, modules |
| [docs/02-advanced.md](docs/02-advanced.md) | Workspaces, remote state, CI/CD integration |
| [examples/](examples/) | 10 real-world infrastructure examples |
| [labs/](labs/) | 3 guided labs (AWS EKS, RDS, VPC) |
| [interview-prep/questions.md](interview-prep/questions.md) | 15 interview Q&A |

---

## Core Workflow

```bash
terraform init      # Download providers, initialize backend
terraform plan      # Preview changes (dry run)
terraform apply     # Apply changes to real infrastructure
terraform destroy   # Tear down infrastructure

# With vars file
terraform plan -var-file=prod.tfvars
terraform apply -var-file=prod.tfvars -auto-approve

# Target specific resource
terraform apply -target=aws_eks_cluster.main

# State operations
terraform state list
terraform state show aws_instance.web
terraform import aws_s3_bucket.existing my-existing-bucket
```
