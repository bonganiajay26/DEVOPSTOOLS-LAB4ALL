# Datadog Integration — AWS
# Monitors EC2, ECS, EKS, RDS, ALB, SQS, and more via CloudWatch

terraform {
  required_providers {
    datadog = {
      source  = "DataDog/datadog"
      version = "~> 3.0"
    }
  }
}

variable "aws_account_id" {}

resource "datadog_integration_aws" "main" {
  account_id = var.aws_account_id
  role_name  = "DatadogIntegrationRole"

  # Only collect tagged production resources (cost control)
  filter_tags = ["env:production"]
  host_tags   = ["env:production", "account:quantum-prod"]

  account_specific_namespace_rules = {
    auto_scaling    = true
    elasticache     = true
    elasticsearch   = true
    sqs             = true
    lambda          = true
    rds             = true
    application_elb = true
  }
}

# ── IAM role (apply in AWS, not Datadog) ─────────────────────────
# aws iam create-role --role-name DatadogIntegrationRole \
#   --assume-role-policy-document file://datadog-trust-policy.json
#
# aws iam attach-role-policy --role-name DatadogIntegrationRole \
#   --policy-arn arn:aws:iam::aws:policy/SecurityAudit
#
# Trust policy (datadog-trust-policy.json):
# {
#   "Version": "2012-10-17",
#   "Statement": [{
#     "Effect": "Allow",
#     "Principal": { "AWS": "arn:aws:iam::464622532012:root" },
#     "Action": "sts:AssumeRole",
#     "Condition": { "StringEquals": { "sts:ExternalId": "<your-external-id-from-datadog>" } }
#   }]
# }
