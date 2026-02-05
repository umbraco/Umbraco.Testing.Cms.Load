# Outputs for the Azure Pipeline

output "hostnames" {
  description = "App Service hostnames (URLs to test against)"
  value       = module.umbraco.hostnames
}

output "cms_versions" {
  description = "Deployed Umbraco CMS versions"
  value       = module.umbraco.cms_versions
}

output "app_service_name" {
  description = "App Service resource names (for start/stop)"
  value       = module.umbraco.app_service_name
}

output "resource_group_name" {
  description = "Resource Group name (for cleanup)"
  value       = var.resource_group_name
}

output "resource_group_location" {
  description = "Azure region"
  value       = var.resource_group_location
}

output "storage_account_name" {
  description = "Storage account for test results"
  value       = module.umbraco.storage_account_name
}
