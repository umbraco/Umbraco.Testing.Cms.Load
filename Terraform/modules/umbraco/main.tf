locals {
  tiers_in_use = toset([for v in var.test_cases : v.tier])

  # Azure SQL admin login must start with a letter; prefix one since random_string can start with a digit.
  sql_admin_login = "u${random_string.admin_login.result}"

  common_tags = {
    project    = "umbraco-loadtest"
    managed_by = "terraform"
    build_id   = var.build_id
  }
}

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.resource_group_location
  tags     = local.common_tags
}

resource "random_string" "admin_login" {
  length  = 15
  special = false
}

# SQL admin password. Azure SQL needs 3 of 4 char categories; force upper+lower+numeric.
resource "random_password" "admin_password" {
  length      = 24
  special     = false
  min_upper   = 1
  min_lower   = 1
  min_numeric = 1
}

# One plan per tier in use; same-tier cases share it (only one app hot at a time).
resource "azurerm_service_plan" "appserviceplan" {
  for_each            = local.tiers_in_use
  name                = "${var.resource_name_prefix}-asp-${lower(each.key)}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  os_type             = "Windows"
  sku_name            = var.tier_specs[each.key].app_sku
  tags                = merge(local.common_tags, { tier = each.key })
}

# ALT resource lives in a long-lived RG (see scripts/ensure-history-infra.ps1).

module "versions" {
  for_each = var.test_cases
  source   = "./versions"

  resource_name_prefix    = var.resource_name_prefix
  resource_group_name     = azurerm_resource_group.rg.name
  resource_group_location = azurerm_resource_group.rg.location
  service_plan_id         = azurerm_service_plan.appserviceplan[each.value.tier].id

  test_case_id         = each.key
  dotnet_version       = each.value.dotnet_version
  umbraco_version      = each.value.umbraco_version
  scenario             = each.value.scenario
  app_settings_overlay = each.value.app_settings_overlay

  admin_login     = local.sql_admin_login
  admin_password  = random_password.admin_password.result
  sql_sku         = var.tier_specs[each.value.tier].sql_sku
  sql_max_size_gb = var.tier_specs[each.value.tier].sql_max_size_gb

  seeder_preset = var.seeder_preset
  common_tags   = local.common_tags

  client_id         = var.client_id
  client_secret     = var.client_secret
  client_oidc_token = var.client_oidc_token
  tenant_id         = var.tenant_id
}
