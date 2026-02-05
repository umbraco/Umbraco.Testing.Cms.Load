# Umbraco Module - Shared Infrastructure
# Creates: Resource Group, App Service Plan, Azure Load Test, and orchestrates per-version deployments

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.resource_group_location
  tags     = var.tags
}

# SQL Server credentials (shared across all versions)
resource "random_string" "admin_login" {
  length     = 16
  special    = false
  numeric    = true
  lower      = true
  upper      = true
  depends_on = [azurerm_resource_group.rg]
}

resource "random_password" "admin_password" {
  length           = 24
  special          = true
  override_special = "!@#$%&*"
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
  depends_on       = [azurerm_resource_group.rg]
}

# Shared App Service Plan (all Umbraco instances share this)
resource "azurerm_service_plan" "appserviceplan" {
  name                = "${var.resource_name_prefix}-appserviceplan"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  os_type             = "Windows"
  sku_name            = var.app_service_plan_sku
  tags                = var.tags
}

resource "azurerm_load_test" "load_test" {
  name                = "${var.resource_name_prefix}-loadtest"
  location            = var.resource_group_location
  resource_group_name = var.resource_group_name
  tags                = var.tags
  depends_on          = [azurerm_service_plan.appserviceplan]
}

# Per-version resources (SQL Server, Database, App Service)
module "versions" {
  for_each = var.umbraco_cms_versions
  source   = "./versions"

  resource_name_prefix    = var.resource_name_prefix
  resource_group_name     = azurerm_resource_group.rg.name
  resource_group_location = azurerm_resource_group.rg.location
  tags                    = var.tags

  service_plan_id = azurerm_service_plan.appserviceplan.id

  dotnet_version      = each.value["dotnet_version"]
  umbraco_cms_version = each.value["umbraco_version"]

  sql_sku         = var.sql_sku
  sql_max_size_gb = var.sql_max_size_gb
  admin_login     = random_string.admin_login.result
  admin_password  = random_password.admin_password.result

  client_id     = var.client_id
  client_secret = var.client_secret
  tenant_id     = var.tenant_id
}
