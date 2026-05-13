output "test_case_values" {
  value = {
    app_service_name       = azurerm_windows_web_app.app_service.name
    app_service_hostname   = azurerm_windows_web_app.app_service.default_hostname
    app_service_plan_id    = var.service_plan_id
    umbraco_version        = var.umbraco_version
    dotnet_version         = var.dotnet_version
    scenario               = var.scenario
    sql_server_name        = var.sql_server_name
    sql_server_resource_id = var.sql_server_id
    sql_database_name      = azurerm_mssql_database.database.name
    sql_database_id        = azurerm_mssql_database.database.id
    elastic_pool_id        = var.elastic_pool_id
  }
}
