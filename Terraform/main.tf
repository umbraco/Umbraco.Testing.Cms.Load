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

  # Resource naming
  resource_name_prefix    = var.resource_name_prefix
  resource_group_name     = var.resource_group_name
  resource_group_location = var.resource_group_location

  # Infrastructure configuration
  app_service_plan_sku = var.app_service_plan_sku
  sql_sku              = var.sql_sku
  sql_max_size_gb      = var.sql_max_size_gb

  # Umbraco versions
  umbraco_cms_versions = var.umbraco_cms_versions
  seeder_preset        = var.seeder_preset

  # Azure credentials
  client_id     = var.client_id
  client_secret = var.client_secret
  tenant_id     = var.tenant_id
}
