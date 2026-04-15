variable "resource_name_prefix" {
  type        = string
  description = "This name will prefix all the created resources"
}

variable "resource_group_name" {
  type        = string
  description = "Name of the resource group that the app service is located in"
}

variable "resource_group_location" {
  type        = string
  description = "Location for the Azure resources"
}

variable "service_plan_id" {
  type        = string
  description = "ID of the service plan the App service will use"
}

variable "dotnet_version" {
  type        = string
  description = "The version of .NET to use"
}

variable "umbraco_cms_version" {
  type        = string
  description = "The version of Umbraco CMS to deploy"
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
  description = "SKU for the SQL Database"
  default     = "S0"
}

variable "sql_max_size_gb" {
  type        = number
  description = "Maximum size of the SQL Database in GB"
  default     = 5
}

variable "seeder_preset" {
  type        = string
  description = "Data seeder preset (Small, Medium, Large, Massive)"
  default     = "Medium"
}
