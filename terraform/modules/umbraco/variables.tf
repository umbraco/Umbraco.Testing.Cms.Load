# Resource Naming & Location
variable "resource_name_prefix" {
  type        = string
  description = "Prefix for all resource names"

  validation {
    condition     = can(regex("^[0-9a-z]([-0-9a-z]{0,98}[0-9a-z])?$", var.resource_name_prefix))
    error_message = "Prefix must be lowercase letters, numbers, and hyphens. Cannot start/end with hyphen. Max 100 chars."
  }
}

variable "resource_group_name" {
  type        = string
  description = "Name of the Azure Resource Group"
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

# Results Storage (created manually, see README)
variable "results_storage_account_name" {
  type        = string
  description = "Storage account name for test results (must be created manually)"
}

# App Service Configuration
variable "app_service_plan_sku" {
  type        = string
  description = "SKU for the shared App Service Plan (S1-S3)"
}

# SQL Database Configuration
variable "sql_sku" {
  type        = string
  description = "SKU for SQL Databases (S0/S1/S2)"
  default     = "S0"
}

variable "sql_max_size_gb" {
  type        = number
  description = "Maximum size of SQL Database in GB"
  default     = 5
}

# Umbraco Versions
variable "umbraco_cms_versions" {
  type = map(object({
    dotnet_version  = string
    umbraco_version = string
  }))
  description = "Map of Umbraco versions to deploy"
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
