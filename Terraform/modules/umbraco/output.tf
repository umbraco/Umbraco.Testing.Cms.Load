output "test_case_outputs" {
  description = "Per-case Terraform outputs, keyed by testCaseId. Only fields consumed by the pipeline are exposed."
  value = {
    for k, m in module.versions : k => {
      hostname            = m.test_case_values.app_service_hostname
      app_service_name    = m.test_case_values.app_service_name
      app_service_plan_id = m.test_case_values.app_service_plan_id
      # Reference the same locals the resources themselves use (main.tf), rather
      # than recomputing the override logic here - so metadata can't silently
      # disagree with what was actually provisioned if the two copies drifted.
      app_service_sku   = local.tier_app_sku[var.test_cases[k].tier]
      pool_dtu_max      = local.tier_db_dtu[var.test_cases[k].tier]
      sql_database_name = m.test_case_values.sql_database_name
      sql_database_id   = m.test_case_values.sql_database_id
    }
  }
}
