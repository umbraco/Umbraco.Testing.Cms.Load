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

variable "unattended_admin_password" {
  type        = string
  description = "Umbraco unattended-install admin password (test-only, randomised per run)"
  sensitive   = true
}

variable "client_id" {
  type        = string
  description = "Azure Service Principal client ID"
  sensitive   = true
}

variable "client_secret" {
  type        = string
  description = "Azure Service Principal client secret"
  sensitive   = true
}

variable "tenant_id" {
  type        = string
  description = "Azure tenant ID"
  sensitive   = true
}

variable "sql_sku" {
  type        = string
  description = "SQL Database SKU"
}

variable "sql_max_size_gb" {
  type        = number
  description = "SQL Database max size in GB"
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
