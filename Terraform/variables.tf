variable "resource_name_prefix" {
  type        = string
  description = "This name will prefix all the created resources"
}

variable "resource_group_location" {
  type        = string
  description = "Azure region for resource deployment"
  default     = "West Europe"
}

variable "resource_group_name" {
  type        = string
  description = "Name of the Azure resource group"
}

variable "client_id" {
  type        = string
  description = "Azure Service Principal client ID"
  default     = "empty"
  sensitive   = true
}

variable "client_secret" {
  type        = string
  description = "Azure Service Principal client secret"
  default     = "empty"
  sensitive   = true
}

variable "tenant_id" {
  type        = string
  description = "Azure tenant ID"
  default     = "empty"
  sensitive   = true
}

# App Service configuration
variable "app_service_plan_sku" {
  type        = string
  description = "SKU for the App Service Plan (S1, S2, S3)"
  default     = "S3"
  validation {
    condition     = contains(["S1", "S2", "S3"], var.app_service_plan_sku)
    error_message = "app_service_plan_sku must be one of: S1, S2, S3"
  }
}

# SQL Database configuration
variable "sql_sku" {
  type        = string
  description = "SKU for the SQL Database (S0, S1, S2)"
  default     = "S0"
  validation {
    condition     = contains(["S0", "S1", "S2"], var.sql_sku)
    error_message = "sql_sku must be one of: S0, S1, S2"
  }
}

variable "sql_max_size_gb" {
  type        = number
  description = "Maximum size of the SQL Database in GB"
  default     = 5
  validation {
    condition     = var.sql_max_size_gb >= 1 && var.sql_max_size_gb <= 100
    error_message = "sql_max_size_gb must be between 1 and 100"
  }
}

# Umbraco versions
variable "umbraco_cms_versions" {
  type = map(object({
    dotnet_version  = string
    umbraco_version = string
  }))
  description = "Map of Umbraco versions to deploy with their .NET runtime versions"
}

# Seeder configuration
variable "seeder_preset" {
  type        = string
  description = "DummyDataSeeder preset (Small, Medium, Large, Massive)"
  default     = "Medium"
  validation {
    condition     = contains(["Small", "Medium", "Large", "Massive"], var.seeder_preset)
    error_message = "seeder_preset must be one of: Small, Medium, Large, Massive"
  }
}
