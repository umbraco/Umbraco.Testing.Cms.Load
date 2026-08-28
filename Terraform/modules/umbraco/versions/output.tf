output "test_case_values" {
  value = {
    app_service_name     = azurerm_windows_web_app.app_service.name
    app_service_hostname = azurerm_windows_web_app.app_service.default_hostname
    app_service_plan_id  = var.service_plan_id
    sql_database_name    = azurerm_mssql_database.database.name
    sql_database_id      = azurerm_mssql_database.database.id
  }
}
