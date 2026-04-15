# Resource group
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.resource_group_location
}

# Random credentials for SQL server (shared across all versions)
resource "random_string" "admin_login" {
  length     = 16
  special    = false
  depends_on = [azurerm_resource_group.rg]
}

resource "random_password" "admin_password" {
  length     = 16
  special    = false
  depends_on = [azurerm_resource_group.rg]
}

# App Service Plan (shared across all versions)
resource "azurerm_service_plan" "appserviceplan" {
  name                = "${var.resource_name_prefix}-appserviceplan"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  os_type             = "Windows"
  sku_name            = var.app_service_plan_sku
}

# NOTE: The Azure Load Testing resource is provisioned out-of-band by
# scripts/bootstrap-history-infra.ps1 in a long-lived "history" RG so its run
# history (and the storage account holding exported metrics) survives across
# pipeline runs. If it lived here, every RG cleanup would wipe the history.

# Per-version infrastructure module
module "versions" {
  for_each = var.umbraco_cms_versions
  source   = "./versions"

  # Resource configuration
  resource_name_prefix    = var.resource_name_prefix
  resource_group_name     = azurerm_resource_group.rg.name
  resource_group_location = azurerm_resource_group.rg.location
  service_plan_id         = azurerm_service_plan.appserviceplan.id

  # Version-specific settings
  dotnet_version      = each.value["dotnet_version"]
  umbraco_cms_version = each.value["umbraco_version"]

  # SQL configuration
  admin_login     = random_string.admin_login.result
  admin_password  = random_password.admin_password.result
  sql_sku         = var.sql_sku
  sql_max_size_gb = var.sql_max_size_gb

  # Seeder configuration
  seeder_preset = var.seeder_preset

  # Azure credentials for deployment
  client_id     = var.client_id
  client_secret = var.client_secret
  tenant_id     = var.tenant_id
}
