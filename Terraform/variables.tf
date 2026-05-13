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

# Override the per-DB DTU cap for every case in the run. 0 = use the tier's
# built-in value from tiers.json. Lets you size SQL independently of the App
# Service tier — useful when comparison data shows the app tier scales but the
# database is the bottleneck. The pool's eDTU capacity is computed from this
# cap (smallest valid Standard pool size that can hold a DB at the cap).
variable "pool_dtu_override" {
  type        = number
  description = "Override per-DB DTU cap for every case (0 = use each tier's default)."
  default     = 0
  validation {
    condition     = var.pool_dtu_override == 0 || contains([10, 20, 50, 100, 200], var.pool_dtu_override)
    error_message = "pool_dtu_override must be 0 (auto) or one of the valid Standard per-DB DTU caps: 10, 20, 50, 100, 200"
  }
}

# Override the App Service Plan SKU for every case in the run. Empty = use
# the tier's built-in value from tiers.json. Counterpart to pool_dtu_override
# on the app side — useful for "is the app saturating before SQL does?" sweeps.
variable "app_sku_override" {
  type        = string
  description = "Override App Service Plan SKU for every case ('' = use each tier's default)."
  default     = ""
  validation {
    condition     = var.app_sku_override == "" || contains(["P0v3", "P1v3", "P2v3", "P3v3"], var.app_sku_override)
    error_message = "app_sku_override must be empty (auto) or one of: P0v3, P1v3, P2v3, P3v3"
  }
}
