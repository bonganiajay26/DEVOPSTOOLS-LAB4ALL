# Datadog Monitors — Terraform
# Covers the 5 core monitors every service needs in production

terraform {
  required_providers {
    datadog = {
      source  = "DataDog/datadog"
      version = "~> 3.0"
    }
  }
}

variable "service" { default = "my-api" }
variable "env"     { default = "production" }
variable "team"    { default = "platform" }
variable "slack_channel" { default = "alerts-critical" }

locals {
  tags = ["env:${var.env}", "service:${var.service}", "team:${var.team}"]
}

# ── 1. Error rate ─────────────────────────────────────────────────
resource "datadog_monitor" "error_rate" {
  name    = "[P1] ${var.service} - Error Rate Critical - ${var.env}"
  type    = "metric alert"
  message = <<-EOT
    {{#is_alert}}
    Error rate is {{value}}% on ${var.service} in ${var.env}.
    - [Dashboard](https://app.datadoghq.com/dashboard)
    - [Runbook](https://wiki.quantum.com/runbooks/${var.service})
    @slack-${var.slack_channel} @pagerduty-critical
    {{/is_alert}}
    {{#is_recovery}}✅ Error rate recovered to {{value}}%{{/is_recovery}}
  EOT

  query = "sum(last_5m):sum:trace.web.request.errors{service:${var.service},env:${var.env}}.as_rate() / sum:trace.web.request.hits{service:${var.service},env:${var.env}}.as_rate() * 100"

  monitor_thresholds {
    critical = 5
    warning  = 2
  }

  tags = local.tags
}

# ── 2. Latency p99 ────────────────────────────────────────────────
resource "datadog_monitor" "latency_p99" {
  name    = "[P2] ${var.service} - High Latency p99 - ${var.env}"
  type    = "metric alert"
  message = <<-EOT
    {{#is_alert}}p99 latency is {{value}}ms. @slack-${var.slack_channel} @pagerduty-warning{{/is_alert}}
    {{#is_recovery}}✅ p99 latency recovered to {{value}}ms{{/is_recovery}}
  EOT

  query = "avg(last_10m):p99:trace.web.request{service:${var.service},env:${var.env}} > 2000"

  monitor_thresholds {
    critical = 2000
    warning  = 1000
  }

  tags = local.tags
}

# ── 3. Host CPU ───────────────────────────────────────────────────
resource "datadog_monitor" "host_cpu" {
  name    = "[P2] ${var.service} - High CPU - ${var.env}"
  type    = "metric alert"
  message = "{{#is_alert}}CPU is {{value}}% on {{host.name}}. @slack-${var.slack_channel}{{/is_alert}}"

  query = "avg(last_15m):avg:system.cpu.user{env:${var.env},service:${var.service}} by {host} > 90"

  monitor_thresholds {
    critical = 90
    warning  = 75
  }

  tags = local.tags
}

# ── 4. Disk space ─────────────────────────────────────────────────
resource "datadog_monitor" "disk_space" {
  name    = "[P3] ${var.service} - Disk Space High - ${var.env}"
  type    = "metric alert"
  message = "{{#is_alert}}Disk {{device}} on {{host.name}} is {{value}}% full. @slack-alerts-warning{{/is_alert}}"

  query = "max(last_15m):max:system.disk.in_use{env:${var.env}} by {host,device} > 0.90"

  monitor_thresholds {
    critical = 0.90
    warning  = 0.75
  }

  tags = local.tags
}

# ── 5. Pod crash loop (Kubernetes) ────────────────────────────────
resource "datadog_monitor" "pod_crash_loop" {
  name    = "[P1] ${var.service} - Pod CrashLoopBackOff - ${var.env}"
  type    = "metric alert"
  message = "{{#is_alert}}Pod {{pod_name.name}} is crash-looping. @slack-${var.slack_channel} @pagerduty-critical{{/is_alert}}"

  query = "change(max(last_15m),last_15m):max:kubernetes.containers.restarts{env:${var.env},kube_deployment:${var.service}} by {pod_name} > 5"

  monitor_thresholds {
    critical = 5
    warning  = 3
  }

  tags = local.tags
}
