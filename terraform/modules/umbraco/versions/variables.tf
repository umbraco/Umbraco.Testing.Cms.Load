# Resource Naming & Location
variable "resource_name_prefix" {
  type        = string
  description = "Prefix for all resource names"
}

variable "resource_group_name" {
  type        = string
  description = "Name of the resource group"
}

variable "resource_group_location" {
  type        = string
  description = "Azure region for resources"
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to all resources"
  default     = {}
}

# App Service Configuration
variable "service_plan_id" {
  type        = string
  description = "ID of the shared App Service Plan"
}

variable "dotnet_version" {
  type        = string
  description = ".NET version (e.g., 'v8.0', 'v9.0')"
}

# Umbraco Configuration
variable "umbraco_cms_version" {
  type        = string
  description = "Umbraco CMS version (e.g., '14.3.0', '15.1.0')"
}

# SQL Database Configuration
variable "sql_sku" {
  type        = string
  description = "SKU for SQL Database (S0/S1/S2)"
  default     = "S0"
}

variable "sql_max_size_gb" {
  type        = number
  description = "Maximum size of SQL Database in GB"
  default     = 5
}

variable "admin_login" {
  type        = string
  description = "SQL Server administrator login"
}

variable "admin_password" {
  type        = string
  description = "SQL Server administrator password"
  sensitive   = true
}

# Azure Credentials (for deployment script)
variable "client_id" {
  type        = string
  description = "Azure Service Principal Client ID"
  sensitive   = true
}

variable "client_secret" {
  type        = string
  description = "Azure Service Principal Client Secret"
  sensitive   = true
}

variable "tenant_id" {
  type        = string
  description = "Azure Tenant ID"
  sensitive   = true
}
