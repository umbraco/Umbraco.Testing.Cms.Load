output "umbraco_version_values" {
  value = {
    app_service_name     = azurerm_windows_web_app.app_service.name
    app_service_hostname = azurerm_windows_web_app.app_service.default_hostname
    umbraco_cms_version  = var.umbraco_cms_version
    dotnet_version       = var.dotnet_version
  }
}
