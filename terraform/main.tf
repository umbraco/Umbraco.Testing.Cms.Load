# Umbraco Load Testing Infrastructure
# Provisions Azure infrastructure for load testing multiple Umbraco versions.
# Usage: terraform init && terraform apply

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">=4.20.0"
    }
  }
  required_version = ">= 1.3.9"
}

provider "azurerm" {
  features {}
}

module "umbraco" {
  source = "./modules/umbraco"

  resource_name_prefix    = var.resource_name_prefix
  resource_group_name     = var.resource_group_name
  resource_group_location = var.resource_group_location
  tags                    = var.tags

  results_storage_account_name = var.results_storage_account_name
  umbraco_cms_versions         = var.umbraco_cms_versions

  app_service_plan_sku = var.app_service_plan_sku
  sql_sku              = var.sql_sku
  sql_max_size_gb      = var.sql_max_size_gb

  client_id     = var.client_id
  client_secret = var.client_secret
  tenant_id     = var.tenant_id
}
