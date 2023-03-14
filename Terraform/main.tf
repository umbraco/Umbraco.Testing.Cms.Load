terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.34.0"
    }
  }

  required_version = ">= 1.3.5"
}

provider "azurerm" {
  features {}
}

module "umbraco" {
  source                  = "./modules/umbraco"
  resource_group_location = var.resource_group_location
  resource_group_name     = var.resource_group_name
}