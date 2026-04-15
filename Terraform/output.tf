output "hostnames" {
  description = "List of App Service hostnames"
  value       = module.umbraco.hostnames
}

output "cms_versions" {
  description = "List of Umbraco CMS versions deployed"
  value       = module.umbraco.cms_versions
}

output "app_service_names" {
  description = "List of App Service names"
  value       = module.umbraco.app_service_names
}

output "dotnet_versions" {
  description = "List of .NET versions (paired by index with cms_versions)"
  value       = module.umbraco.dotnet_versions
}
