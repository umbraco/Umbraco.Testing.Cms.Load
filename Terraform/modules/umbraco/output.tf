output "test_case_outputs" {
  description = "Per-case Terraform outputs, keyed by testCaseId"
  value = {
    for k, m in module.versions : k => {
      hostname               = m.test_case_values.app_service_hostname
      app_service_name       = m.test_case_values.app_service_name
      app_service_plan_id    = m.test_case_values.app_service_plan_id
      umbraco_version        = m.test_case_values.umbraco_version
      dotnet_version         = m.test_case_values.dotnet_version
      tier                   = var.test_cases[k].tier
      scenario               = m.test_case_values.scenario
      app_service_sku        = var.tier_specs[var.test_cases[k].tier].app_sku
      # Reflect the override here so downstream metadata (NDJSON, ALT run description)
      # records the SKU actually provisioned, not the tier's nominal pairing.
      sql_sku                = var.sql_sku_override != "" ? var.sql_sku_override : var.tier_specs[var.test_cases[k].tier].sql_sku
      sql_server_name        = m.test_case_values.sql_server_name
      sql_server_resource_id = m.test_case_values.sql_server_resource_id
      sql_database_name      = m.test_case_values.sql_database_name
      sql_database_id        = m.test_case_values.sql_database_id
    }
  }
}
