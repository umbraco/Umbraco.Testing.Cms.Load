variable "resource_name_prefix" {
  type        = string
  description = "Prefix for all created resources. Capped at 16 chars to fit Azure App Service's 60-char name limit once the per-case suffix is appended."

  validation {
    condition     = length(var.resource_name_prefix) <= 16 && can(regex("^[0-9a-z]([-0-9a-z]{0,14}[0-9a-z])?$", var.resource_name_prefix))
    error_message = "resource_name_prefix must be 1-16 chars, lowercase alphanumeric + hyphens, not starting or ending with hyphen."
  }
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

variable "test_cases" {
  type = map(object({
    dotnet_version       = string
    umbraco_version      = string
    tier                 = string
    scenario             = string
    app_settings_overlay = map(string)
  }))
  description = "Map of test cases keyed by '{umbraco}__{tier}__{scenario}'. Built by scripts/prepare-test-cases.ps1 from the pipeline's testCases parameter."
}

# Surfaces in resource tags. Defaults to "local" for hand runs.
variable "build_id" {
  type        = string
  description = "Pipeline build ID (or 'local'). Used as a tag on every resource."
  default     = "local"
}

variable "seeder_preset" {
  type        = string
  description = "Data seeder preset (Small, Medium, Large, Massive)"
  default     = "Medium"
  validation {
    condition     = contains(["Small", "Medium", "Large", "Massive"], var.seeder_preset)
    error_message = "seeder_preset must be one of: Small, Medium, Large, Massive"
  }
}
