# Example 05: Reusable Terraform Modules — Complete Pattern

# ══════════════════════════════════════════
# MODULE: modules/web-app/main.tf
# Deploy a web application with all supporting infrastructure
# ══════════════════════════════════════════

# modules/web-app/variables.tf
variable "name"        { type = string }
variable "environment" { type = string }
variable "vpc_id"      { type = string }
variable "subnet_ids"  { type = list(string) }
variable "container_image" { type = string }
variable "cpu"          { default = 256 }
variable "memory"       { default = 512 }
variable "desired_count" { default = 2 }
variable "min_count"    { default = 2 }
variable "max_count"    { default = 10 }
variable "health_check_path" { default = "/health" }
variable "environment_variables" {
  type    = map(string)
  default = {}
}
variable "secrets" {
  type    = map(string)
  default = {}
  description = "Map of env var name to Secrets Manager ARN"
}
variable "tags" {
  type    = map(string)
  default = {}
}

# modules/web-app/outputs.tf
output "alb_dns_name"      { value = aws_lb.main.dns_name }
output "service_arn"       { value = aws_ecs_service.main.id }
output "task_definition"   { value = aws_ecs_task_definition.main.arn }
output "target_group_arn"  { value = aws_lb_target_group.main.arn }

# ══════════════════════════════════════════
# ROOT MODULE: Using the web-app module
# ══════════════════════════════════════════

# environments/production/main.tf

# Use VPC module (community module)
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "production-vpc"
  cidr = "10.0.0.0/16"
  azs  = ["us-east-1a", "us-east-1b", "us-east-1c"]

  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = false   # One NAT per AZ for HA
}

# Deploy multiple services using the same module
module "api_service" {
  source = "../../modules/web-app"

  name        = "api"
  environment = "production"
  vpc_id      = module.vpc.vpc_id
  subnet_ids  = module.vpc.private_subnets

  container_image = "123456789.dkr.ecr.us-east-1.amazonaws.com/api:v2.3.1"
  cpu     = 1024
  memory  = 2048
  desired_count = 5

  environment_variables = {
    APP_ENV   = "production"
    LOG_LEVEL = "info"
    REDIS_URL = "redis://${module.redis.endpoint}:6379"
  }

  secrets = {
    DATABASE_URL = aws_secretsmanager_secret.db_url.arn
    JWT_SECRET   = aws_secretsmanager_secret.jwt.arn
  }

  tags = local.common_tags
}

module "worker_service" {
  source = "../../modules/web-app"

  name        = "worker"
  environment = "production"
  vpc_id      = module.vpc.vpc_id
  subnet_ids  = module.vpc.private_subnets

  container_image = "123456789.dkr.ecr.us-east-1.amazonaws.com/worker:v2.3.1"
  cpu           = 512
  memory        = 1024
  desired_count = 3
  health_check_path = "/healthz"

  secrets = {
    DATABASE_URL  = aws_secretsmanager_secret.db_url.arn
    QUEUE_URL     = aws_secretsmanager_secret.queue_url.arn
  }

  tags = local.common_tags
}

# Use the RDS module from Example 02
module "database" {
  source = "../../modules/rds-postgres"

  environment = "production"
  db_name     = "appdb"
  vpc_id      = module.vpc.vpc_id
  subnet_ids  = module.vpc.private_subnets
  app_sg_id   = module.api_service.security_group_id
}

locals {
  common_tags = {
    Environment = "production"
    ManagedBy   = "terraform"
    Project     = "myapp"
    CostCenter  = "engineering"
  }
}

# Outputs from modules
output "api_url"        { value = "https://${module.api_service.alb_dns_name}" }
output "db_secret_arn"  { value = module.database.db_secret_arn }
