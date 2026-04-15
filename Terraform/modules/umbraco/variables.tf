variable "resource_group_location" {
  type        = string
  description = "Azure region for resource deployment"
}

variable "resource_group_name" {
  type        = string
  description = "Name of the Azure resource group"
}

variable "resource_name_prefix" {
  type        = string
  description = "This name will prefix all the created resources"
  validation {
    condition     = can(regex("^[0-9a-z]([-0-9a-z]{0,100}[0-9a-z])?$", var.resource_name_prefix))
    error_message = "The prefix can contain only lowercase letters, numbers, and '-', but can't start or end with '-' or have more than 100 characters."
  }
}

variable "umbraco_cms_versions" {
  type = map(object({
    dotnet_version  = string
    umbraco_version = string
  }))
  description = "Map of Umbraco versions to deploy with their .NET runtime versions"
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

variable "app_service_plan_sku" {
  type        = string
  description = "SKU for the App Service Plan"
  default     = "P1v3"
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
