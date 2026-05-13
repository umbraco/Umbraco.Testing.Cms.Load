variable "resource_name_prefix" {
  type        = string
  description = "Prefix for all created resources"
}

variable "resource_group_name" {
  type        = string
  description = "Resource group the App Service lives in"
}

variable "resource_group_location" {
  type        = string
  description = "Azure region"
}

variable "service_plan_id" {
  type        = string
  description = "ID of the App Service Plan this case attaches to"
}

variable "dotnet_version" {
  type        = string
  description = ".NET runtime version (e.g. v10.0)"
}

variable "umbraco_version" {
  type        = string
  description = "Umbraco CMS version (e.g. 17.0.0)"
}

variable "scenario" {
  type        = string
  description = "Scenario name, surfaced in test_case_outputs for tagging."
}

variable "test_case_id" {
  type        = string
  description = "Unique case identifier ({umbraco}__{tier}__{scenario}); used as the per-case resource-name suffix."
}

variable "app_settings_overlay" {
  type        = map(string)
  description = "Already-flattened App Service app_settings overlay; overlay keys win over base keys."
  default     = {}
}

variable "admin_login" {
  type        = string
  description = "SQL Server admin login"
  sensitive   = true
}

variable "admin_password" {
  type        = string
  description = "SQL Server admin password"
  sensitive   = true
}

variable "sql_server_name" {
  type        = string
  description = "Name of the shared per-tier SQL server hosting this case's database"
}

variable "sql_server_id" {
  type        = string
  description = "Resource ID of the shared per-tier SQL server"
}

variable "sql_server_fqdn" {
  type        = string
  description = "Fully qualified domain name of the shared per-tier SQL server"
}

variable "elastic_pool_id" {
  type        = string
  description = "ID of the per-tier Elastic Pool this case's database joins"
}

variable "sql_firewall_rule_dependency" {
  type        = string
  description = "Pass-through ID of the parent module's firewall rule, used only to express the create-order dependency in the versions submodule."
}

variable "seeder_preset" {
  type        = string
  description = "Data seeder preset (Small, Medium, Large, Massive)"
  default     = "Medium"
}

variable "common_tags" {
  type        = map(string)
  description = "Common tags applied to every per-case resource (merged with case-specific tags)"
  default     = {}
}
