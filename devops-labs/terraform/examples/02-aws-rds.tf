# Example 02: AWS RDS PostgreSQL with Multi-AZ, Backups, and Encryption

terraform {
  required_providers {
    aws  = { source = "hashicorp/aws", version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.0" }
  }
}

variable "environment"    { default = "production" }
variable "db_name"        { default = "appdb" }
variable "db_username"    { default = "appuser" }
variable "vpc_id"         {}
variable "subnet_ids"     { type = list(string) }
variable "app_sg_id"      {}

locals {
  identifier = "${var.environment}-postgres"
}

# Random password (stored in AWS Secrets Manager)
resource "random_password" "db" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}:?"
}

resource "aws_secretsmanager_secret" "db_password" {
  name                    = "${var.environment}/database/password"
  recovery_window_in_days = 7   # 0 = immediate delete (use in dev only)
  description             = "PostgreSQL password for ${local.identifier}"
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id = aws_secretsmanager_secret.db_password.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
    host     = aws_db_instance.main.address
    port     = aws_db_instance.main.port
    dbname   = var.db_name
    url      = "postgresql://${var.db_username}:${random_password.db.result}@${aws_db_instance.main.address}:5432/${var.db_name}"
  })
}

# Security group — only allow app tier
resource "aws_security_group" "db" {
  name        = "${local.identifier}-sg"
  description = "Database security group"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.app_sg_id]
    description     = "PostgreSQL from application tier"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.identifier}-sg" }
}

# Subnet group
resource "aws_db_subnet_group" "main" {
  name       = local.identifier
  subnet_ids = var.subnet_ids
  tags       = { Name = local.identifier }
}

# Parameter group for PostgreSQL tuning
resource "aws_db_parameter_group" "postgres15" {
  name   = "${local.identifier}-pg15"
  family = "postgres15"

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"    # Log queries > 1 second
  }
  parameter {
    name  = "log_connections"
    value = "1"
  }
  parameter {
    name  = "shared_preload_libraries"
    value = "pg_stat_statements"
  }
}

# KMS key for RDS encryption
resource "aws_kms_key" "rds" {
  description             = "KMS key for RDS encryption: ${local.identifier}"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

# RDS instance
resource "aws_db_instance" "main" {
  identifier = local.identifier

  # Engine
  engine               = "postgres"
  engine_version       = "15.5"
  instance_class       = var.environment == "production" ? "db.r6g.large" : "db.t3.micro"

  # Storage
  allocated_storage     = 100
  max_allocated_storage = 1000   # Auto-scaling storage (up to 1TB)
  storage_type          = "gp3"
  iops                  = var.environment == "production" ? 3000 : null
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.rds.arn

  # Database
  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result

  # Networking
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false

  # High availability
  multi_az = var.environment == "production"

  # Backups
  backup_retention_period   = var.environment == "production" ? 30 : 7
  backup_window             = "03:00-04:00"
  maintenance_window        = "sun:04:00-sun:05:00"
  delete_automated_backups  = false
  copy_tags_to_snapshot     = true

  # Monitoring
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  monitoring_interval              = 60   # Enhanced monitoring every 60s
  monitoring_role_arn              = aws_iam_role.rds_monitoring.arn
  performance_insights_enabled     = var.environment == "production"
  performance_insights_retention_period = 7

  # Parameters
  parameter_group_name = aws_db_parameter_group.postgres15.name

  # Protection
  deletion_protection      = var.environment == "production"
  skip_final_snapshot      = var.environment != "production"
  final_snapshot_identifier = var.environment == "production" ? "${local.identifier}-final" : null

  lifecycle {
    prevent_destroy = true   # Terraform plan will fail if you try to destroy this
    ignore_changes  = [password]   # Managed by rotation, don't override
  }

  tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# IAM role for enhanced monitoring
resource "aws_iam_role" "rds_monitoring" {
  name               = "${local.identifier}-monitoring"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
    }]
  })
  managed_policy_arns = ["arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"]
}

# CloudWatch alarm for high CPU
resource "aws_cloudwatch_metric_alarm" "db_cpu" {
  alarm_name          = "${local.identifier}-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = "300"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "Database CPU > 80% for 10 minutes"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.identifier
  }
}

# Outputs
output "db_endpoint"          { value = aws_db_instance.main.address }
output "db_port"              { value = aws_db_instance.main.port }
output "db_secret_arn"        { value = aws_secretsmanager_secret.db_password.arn }
output "connection_string"    {
  value     = "postgresql://${var.db_username}@${aws_db_instance.main.address}:5432/${var.db_name}"
  sensitive = false
}
