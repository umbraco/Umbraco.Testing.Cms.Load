terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.20"
    }
  }

  required_version = ">= 1.3.9"

  # Local state is fine for the ephemeral RG-per-run model. Uncomment the backend below
  # for shared state (pre-create the `tfstate` container in the history storage account).
  # backend "azurerm" {
  #   resource_group_name  = "umbraco-loadtest-history-rg"
  #   storage_account_name = "<your-history-storage-account>"
  #   container_name       = "tfstate"
  #   key                  = "loadtest.tfstate"
  # }
}

provider "azurerm" {
  features {}
}

# Read tier catalog from loadtests/tiers.json.
locals {
  tier_specs = jsondecode(file("${path.module}/../loadtests/tiers.json")).tiers
}

module "umbraco" {
  source = "./modules/umbraco"

  resource_name_prefix    = var.resource_name_prefix
  resource_group_name     = var.resource_group_name
  resource_group_location = var.resource_group_location

  tier_specs        = local.tier_specs
  test_cases        = var.test_cases
  seeder_preset     = var.seeder_preset
  pool_dtu_override = var.pool_dtu_override

  build_id = var.build_id
}
