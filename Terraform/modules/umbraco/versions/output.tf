output "test_case_values" {
  value = {
    app_service_name       = azurerm_windows_web_app.app_service.name
    app_service_hostname   = azurerm_windows_web_app.app_service.default_hostname
    umbraco_version        = var.umbraco_version
    dotnet_version         = var.dotnet_version
    scenario               = var.scenario
    sql_server_name        = azurerm_mssql_server.sql_server.name
    sql_server_resource_id = azurerm_mssql_server.sql_server.id
    sql_database_name      = azurerm_mssql_database.database.name
  }
}
