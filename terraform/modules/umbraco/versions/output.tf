output "umbraco_version_values" {
  description = "Info about this Umbraco instance"
  value = {
    appserviceName      = azurerm_windows_web_app.appservice.name
    appserviceHostname  = azurerm_windows_web_app.appservice.default_hostname
    umbraco_cms_version = var.umbraco_cms_version
  }
}
