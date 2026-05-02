# Example 03: GCP GKE Autopilot Cluster with Workload Identity

terraform {
  required_providers {
    google = { source = "hashicorp/google", version = "~> 5.0" }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

variable "project_id"  {}
variable "region"      { default = "us-central1" }
variable "environment" { default = "production" }

locals {
  cluster_name = "${var.environment}-gke"
}

# VPC
resource "google_compute_network" "vpc" {
  name                    = "${local.cluster_name}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${local.cluster_name}-subnet"
  ip_cidr_range = "10.0.0.0/20"
  region        = var.region
  network       = google_compute_network.vpc.id

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.100.0.0/16"
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.101.0.0/20"
  }

  private_ip_google_access = true
}

# GKE Autopilot cluster
resource "google_container_cluster" "main" {
  name     = local.cluster_name
  location = var.region

  # Autopilot: fully managed, no node management
  enable_autopilot = true

  network    = google_compute_network.vpc.name
  subnetwork = google_compute_subnetwork.subnet.name

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Private cluster (nodes have no public IPs)
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false   # Allow kubectl from internet with auth
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = "0.0.0.0/0"   # Restrict to VPN CIDR in production
      display_name = "Allow all (restrict in prod!)"
    }
  }

  # Workload Identity
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Security
  binary_authorization {
    evaluation_mode = "PROJECT_SINGLETON_POLICY_ENFORCE"
  }

  # Logging and monitoring (use GCP managed)
  logging_service    = "logging.googleapis.com/kubernetes"
  monitoring_service = "monitoring.googleapis.com/kubernetes"

  release_channel {
    channel = "REGULAR"   # Auto-upgrade
  }

  lifecycle {
    ignore_changes = [
      initial_node_count,
      node_config,
    ]
  }
}

# GCP Service Account for app
resource "google_service_account" "app" {
  account_id   = "${var.environment}-app-sa"
  display_name = "App Service Account"
  project      = var.project_id
}

# Grant minimal permissions to service account
resource "google_project_iam_member" "app_secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.app.email}"
}

resource "google_project_iam_member" "app_storage_reader" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${google_service_account.app.email}"
}

# Workload Identity binding: K8s SA → GCP SA
resource "google_service_account_iam_member" "workload_identity" {
  service_account_id = google_service_account.app.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[production/app-sa]"
}

# Outputs
output "cluster_name"      { value = google_container_cluster.main.name }
output "cluster_endpoint"  { value = google_container_cluster.main.endpoint }
output "configure_kubectl" {
  value = "gcloud container clusters get-credentials ${local.cluster_name} --region ${var.region} --project ${var.project_id}"
}
output "gcp_service_account" { value = google_service_account.app.email }
