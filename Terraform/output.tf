#output "resource_name_prefix" {
#  value = var.resource_name_prefix
#}

#output "resource_group_name" {
#  value = var.resource_group_name
#}

#output "resource_group_location" {
#  value = var.resource_group_location
#}

#output "umbraco_versions" {
#  value = module.umbraco.versions_output
#}

output "umbraco_version_hostnames" {
  value = module.umbraco.verions_hostnames_output
}