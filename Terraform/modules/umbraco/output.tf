output "versions_output" {
  value = {
    for version_key, module_version in module.versions :
    version_key => {
      app_service_name     = module_version.umbraco_version_values.app_service_name
      app_service_hostname = module_version.umbraco_version_values.app_service_hostname
      umbraco_cms_version  = module_version.umbraco_version_values.umbraco_cms_version
    }
  }
}

output "hostnames" {
  description = "List of App Service hostnames"
  value = [
    for module_version in module.versions :
    module_version.umbraco_version_values.app_service_hostname
  ]
}

output "cms_versions" {
  description = "List of Umbraco CMS versions deployed"
  value = [
    for module_version in module.versions :
    module_version.umbraco_version_values.umbraco_cms_version
  ]
}

output "app_service_names" {
  description = "List of App Service names"
  value = [
    for module_version in module.versions :
    module_version.umbraco_version_values.app_service_name
  ]
}

output "dotnet_versions" {
  description = "List of .NET versions deployed (paired by index with cms_versions)"
  value = [
    for module_version in module.versions :
    module_version.umbraco_version_values.dotnet_version
  ]
}
