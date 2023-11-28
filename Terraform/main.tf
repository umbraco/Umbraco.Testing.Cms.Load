terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      version = "3.82.0"
    }
  }

  required_version = ">= 1.3.9"
}

provider "azurerm" {
  features {}
}

module "umbraco" {
  source                  = "./modules/umbraco"
  resource_name_prefix    = var.resource_name_prefix
  resource_group_location = var.resource_group_location
  resource_group_name     = var.resource_group_name
  umbraco_cms_versions    = var.umbraco_cms_versions
  # Azure Login Credentials 
  client_id     = var.client_id
  client_secret = var.client_secret
  tenant_id     = var.tenant_id
  app_service_plan_sku = var.app_service_plan_sku
}