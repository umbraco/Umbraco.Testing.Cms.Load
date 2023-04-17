terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "3.34.0"
    }
  }

  required_version = ">= 1.3.9"

  # When using locally comment out the backend code, when running on pipeline uncomment the code
  /*
  backend "azurerm" {
    resource_group_name  = var.bkstrgrg
    storage_account_name = var.bkstrg
    container_name       = var.bkcontainer
    key                  = var.bkstrgkey
  }
  */
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
  client_id               = var.client_id
  client_secret           = var.client_secret
  tenant_id               = var.tenant_id
}