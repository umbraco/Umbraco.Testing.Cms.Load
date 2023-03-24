terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.34.0"
    }
  }

  required_version = ">= 1.3.5"

  # I'm gonna ignore the terraform state. And run the command 'az group delete -g rg-name' at the end of my pipeline so all the resources are deleted.
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
  resource_group_location = var.resource_group_location
  resource_group_name     = var.resource_group_name
}