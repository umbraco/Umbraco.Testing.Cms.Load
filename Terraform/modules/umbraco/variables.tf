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
  description = "Prefix for all created resources. Validated at the root module (max 16 chars)."
}

variable "tier_specs" {
  type = map(object({
    app_sku = string
    dtu_max = number
  }))
  description = "Decoded tier catalog (loadtests/tiers.json), keyed by tier name."
}

variable "test_cases" {
  type = map(object({
    dotnet_version       = string
    umbraco_version      = string
    tier                 = string
    scenario             = string
    app_settings_overlay = map(string)
  }))
  description = "Map of test cases keyed by '{umbraco}__{tier}__{scenario}'."
}

variable "seeder_preset" {
  type        = string
  description = "Data seeder preset (Small, Medium, Large, Massive)"
  default     = "Medium"
}

variable "pool_dtu_override" {
  type        = number
  description = "Override per-DB DTU cap for every case (0 = use each tier's default from tier_specs)."
  default     = 0
}

variable "build_id" {
  type        = string
  description = "Pipeline build ID, surfaced as a resource tag"
  default     = "local"
}
