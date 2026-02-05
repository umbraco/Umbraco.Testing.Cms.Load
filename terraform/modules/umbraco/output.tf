# Outputs aggregated from all version instances

output "versions_output" {
  description = "Detailed info about each deployed version"
  value = {
    for version_key, module_versions in module.versions :
    version_key => {
      appserviceName      = module_versions.umbraco_version_values.appserviceName
      appserviceHostname  = module_versions.umbraco_version_values.appserviceHostname
      umbraco_cms_version = module_versions.umbraco_version_values.umbraco_cms_version
    }
  }
}

output "hostnames" {
  description = "List of App Service hostnames"
  value       = [for m in module.versions : m.umbraco_version_values.appserviceHostname]
}

output "cms_versions" {
  description = "List of deployed Umbraco versions"
  value       = [for m in module.versions : m.umbraco_version_values.umbraco_cms_version]
}

output "app_service_name" {
  description = "List of App Service resource names"
  value       = [for m in module.versions : m.umbraco_version_values.appserviceName]
}

output "storage_account_name" {
  description = "Storage account for test results (created manually)"
  value       = var.results_storage_account_name
}
