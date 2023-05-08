output "versions_output" {
  value = {
    for version_list, module_versions in module.versions :
    version_list => ({ "resource_group_name" = module_versions.umbraco_version_values.resource_group_name, "appserviceName" = module_versions.umbraco_version_values.appserviceName, "appserviceHostname" = module_versions.umbraco_version_values.appserviceHostname, "umbraco_cms_version" = module_versions.umbraco_version_values.umbraco_cms_version })
  }
}

output "hostnames" {
  value = [
    for module_versions in module.versions :
    module_versions.umbraco_version_values.appserviceHostname
  ]
}

output "cms_versions" {
  value = [
    for module_versions in module.versions :
    module_versions.umbraco_version_values.umbraco_cms_version
  ]
}

output app_service_name {
  value = [
    for module_versions in module.versions :
    module_versions.umbraco_version_values.appserviceName
  ]
}