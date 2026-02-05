# Root Module Variables
# Copy terraform.tfvars.example to terraform.tfvars and set your values.

# Resource Naming & Location
variable "resource_name_prefix" {
  type        = string
  description = "Prefix for all Azure resource names (lowercase, numbers, hyphens only)"

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
  description = "Azure region for all resources"
  default     = "West Europe"
}

variable "tags" {
  type        = map(string)
  description = "Tags for cost tracking and organization"
  default = {
    Purpose   = "Load Testing"
    ManagedBy = "Terraform"
  }
}

# Results Storage (created manually - see Prerequisites in docs)
variable "results_storage_account_name" {
  type        = string
  description = "Storage account name for permanent test results"
}

# App Service Configuration
variable "app_service_plan_sku" {
  type        = string
  description = "SKU for the App Service Plan"
  default     = "S3"

  validation {
    condition     = contains(["S1", "S2", "S3"], var.app_service_plan_sku)
    error_message = "Must be one of: S1, S2, S3"
  }
}

# SQL Database Configuration
variable "sql_sku" {
  type        = string
  description = "SKU for SQL Databases (S0=10 DTU, S1=20 DTU, S2=50 DTU)"
  default     = "S0"

  validation {
    condition     = contains(["S0", "S1", "S2"], var.sql_sku)
    error_message = "Must be one of: S0, S1, S2"
  }
}

variable "sql_max_size_gb" {
  type        = number
  description = "Maximum size of each SQL Database in GB"
  default     = 5

  validation {
    condition     = var.sql_max_size_gb >= 1 && var.sql_max_size_gb <= 100
    error_message = "Must be between 1 and 100"
  }
}

# Umbraco Versions
variable "umbraco_cms_versions" {
  type = map(object({
    dotnet_version  = string
    umbraco_version = string
  }))
  description = "Map of Umbraco versions to deploy. Key becomes part of resource names."
}

# Azure Service Principal (used by deployment script)
variable "client_id" {
  type        = string
  description = "Azure Service Principal Client ID"
  default     = "empty"
  sensitive   = true
}

variable "client_secret" {
  type        = string
  description = "Azure Service Principal Client Secret"
  default     = "empty"
  sensitive   = true
}

variable "tenant_id" {
  type        = string
  description = "Azure Tenant ID"
  default     = "empty"
  sensitive   = true
}
