output "test_case_outputs" {
  description = "Per-case Terraform outputs, keyed by testCaseId. Only fields consumed by the pipeline are exposed."
  value = {
    for k, m in module.versions : k => {
      hostname            = m.test_case_values.app_service_hostname
      app_service_name    = m.test_case_values.app_service_name
      app_service_plan_id = m.test_case_values.app_service_plan_id
      # app_sku and pool_dtu reflect the override when set, so downstream metadata
      # records what was actually provisioned, not the tier's nominal value.
      app_service_sku     = var.app_sku_override != "" ? var.app_sku_override : var.tier_specs[var.test_cases[k].tier].app_sku
      pool_dtu_max        = var.pool_dtu_override != 0 ? var.pool_dtu_override : var.tier_specs[var.test_cases[k].tier].dtu_max
      sql_database_name   = m.test_case_values.sql_database_name
      sql_database_id     = m.test_case_values.sql_database_id
    }
  }
}
