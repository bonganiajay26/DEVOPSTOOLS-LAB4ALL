# Example 04: Azure AKS Cluster with Workload Identity and Key Vault

terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 3.0" }
    azuread = { source = "hashicorp/azuread", version = "~> 2.0" }
  }
}

provider "azurerm" {
  features {
    resource_group { prevent_deletion_if_contains_resources = true }
    key_vault { purge_soft_delete_on_destroy = false }
  }
}

variable "location"    { default = "eastus" }
variable "environment" { default = "production" }
variable "prefix"      { default = "myapp" }

locals {
  name = "${var.prefix}-${var.environment}"
}

data "azurerm_client_config" "current" {}

# Resource Group
resource "azurerm_resource_group" "main" {
  name     = "${local.name}-rg"
  location = var.location
  tags     = { environment = var.environment, managed_by = "terraform" }
}

# VNet
resource "azurerm_virtual_network" "main" {
  name                = "${local.name}-vnet"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = ["10.0.0.0/8"]
}

resource "azurerm_subnet" "aks" {
  name                 = "aks-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.1.0.0/16"]
}

# AKS Cluster
resource "azurerm_kubernetes_cluster" "main" {
  name                = "${local.name}-aks"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  dns_prefix          = local.name

  # K8s version
  kubernetes_version  = "1.29"
  automatic_channel_upgrade = "patch"

  # Default node pool
  default_node_pool {
    name                = "system"
    vm_size             = "Standard_D4s_v5"
    node_count          = 3
    min_count           = 2
    max_count           = 10
    enable_auto_scaling = true
    vnet_subnet_id      = azurerm_subnet.aks.id
    type                = "VirtualMachineScaleSets"
    zones               = ["1", "2", "3"]
    os_disk_size_gb     = 128
    os_disk_type        = "Managed"

    node_labels = {
      "nodepool-type" = "system"
    }
  }

  # Identity (System-assigned Managed Identity)
  identity { type = "SystemAssigned" }

  # Workload Identity
  workload_identity_enabled = true
  oidc_issuer_enabled       = true

  # Networking
  network_profile {
    network_plugin     = "azure"
    network_policy     = "calico"
    load_balancer_sku  = "standard"
    service_cidr       = "10.2.0.0/16"
    dns_service_ip     = "10.2.0.10"
  }

  # Monitoring
  microsoft_defender { log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id }
  oms_agent { log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id }

  # Azure AD RBAC
  azure_active_directory_role_based_access_control {
    managed            = true
    azure_rbac_enabled = true
  }
}

# Additional user node pool for app workloads
resource "azurerm_kubernetes_cluster_node_pool" "app" {
  name                  = "app"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = "Standard_D4s_v5"
  node_count            = 3
  min_count             = 2
  max_count             = 20
  enable_auto_scaling   = true
  vnet_subnet_id        = azurerm_subnet.aks.id
  zones                 = ["1", "2", "3"]
  mode                  = "User"

  node_labels = {
    "nodepool-type" = "application"
  }
}

# Key Vault
resource "azurerm_key_vault" "main" {
  name                       = "${var.prefix}-${var.environment}-kv"
  location                   = azurerm_resource_group.main.location
  resource_group_name        = azurerm_resource_group.main.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "premium"
  soft_delete_retention_days = 90
  purge_protection_enabled   = true

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id
    secret_permissions = ["Get", "List", "Set", "Delete", "Purge"]
  }
}

# Log Analytics
resource "azurerm_log_analytics_workspace" "main" {
  name                = "${local.name}-law"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

# Outputs
output "cluster_name"          { value = azurerm_kubernetes_cluster.main.name }
output "kube_config_command"   {
  value = "az aks get-credentials --resource-group ${azurerm_resource_group.main.name} --name ${azurerm_kubernetes_cluster.main.name}"
}
output "key_vault_uri"         { value = azurerm_key_vault.main.vault_uri }
output "oidc_issuer_url"       { value = azurerm_kubernetes_cluster.main.oidc_issuer_url }
