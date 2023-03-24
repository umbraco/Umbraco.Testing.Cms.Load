<<<<<<< Updated upstream
# App Service Plan
resource "azurerm_service_plan" "appserviceplan" {
  name                = "${var.resource_group_name}-appserviceplan"
  location            = var.resource_group_location
  resource_group_name = var.resource_group_name

  os_type  = "Windows"
  sku_name = "S1"
=======
# Resource group
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.resource_group_location
}

# Random string for SQL server login
resource "random_string" "admin_login" {
  length  = 16
  special = true
}

resource "random_password" "admin_password" {
  length  = 16
  special = true
}

# App Service Plan
resource "azurerm_service_plan" "appserviceplan" {
  name                    = "${var.resource_name_prefix}-appserviceplan"
  location                = azurerm_resource_group.rg.location
  resource_group_name     = azurerm_resource_group.rg.name
  os_type                 = "Windows"
  sku_name                = "S1"
}

# We create a module called versions, the reason for that is because we want to have multiple app services with different Umbraco Versions. You can define the versions you want to test in the variables.ts
module "versions" {
  # We use a for_each so it creates a module for each version of Umbraco we have defined in variables.
  for_each                = var.umbraco_cms_versions
  source                  = "./versions"
  resource_name_prefix    = var.resource_name_prefix
  resource_group_name     = azurerm_resource_group.rg.name
  resource_group_location = azurerm_resource_group.rg.location
  service_plan_id         = azurerm_service_plan.appserviceplan.id
  version_name            = each.value["version_name"]
  dotnet_version          = each.value["dotnet_version"]
  umbraco_cms_version     = each.value["umbraco_version"]
  admin_login             = random_string.admin_login.result
  admin_password          = random_password.admin_password.result
>>>>>>> Stashed changes
}