# App Service Plan
resource "azurerm_service_plan" "appserviceplan" {
  name                = "${var.resource_group_name}-appserviceplan"
  location            = var.resource_group_location
  resource_group_name = var.resource_group_name

  os_type  = "Windows"
  sku_name = "S1"
}