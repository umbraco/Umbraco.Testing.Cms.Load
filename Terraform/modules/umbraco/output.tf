output "versions_output" {
  value = {
    for version_list, module_versions in module.versions : 
        version_list =>  ({ "resource_group_name" =  module_versions.umbraco_version_values.resource_group_name, "appserviceName" = module_versions.umbraco_version_values.appserviceName, "appserviceHostname" = module_versions.umbraco_version_values.appserviceHostname, "umbraco_cms_version" =  module_versions.umbraco_version_values.umbraco_cms_version })
          }
}

output "verions_hostnames_output" {
  value = {
    for host_names, module_versions in module.versions : 
        host_names => module_versions.umbraco_version_values.appserviceHostname
          }
}

output "versions_hostnames" {
  value = values(module.versions)[*].umbraco_version_values.appserviceHostname
  }

output "hostnames" {
  value = [
    for module_versions in module.versions : 
        module_versions.umbraco_version_values.appserviceHostname
          ]
}

output "load_test_name" {
  value = azurerm_load_test.load_test.name
}