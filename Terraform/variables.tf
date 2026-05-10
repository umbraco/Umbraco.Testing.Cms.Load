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

# Override the SQL SKU for every case in the run. Empty string = use the tier's
# built-in pairing from tiers.json. Lets you size SQL independently of the App
# Service tier — useful when comparison data shows the app tier scales but the
# database is the bottleneck.
variable "sql_sku_override" {
  type        = string
  description = "Override SQL DB SKU for every case ('' = use each tier's default)."
  default     = ""
  validation {
    condition     = var.sql_sku_override == "" || contains(["S0", "S1", "S2", "S3"], var.sql_sku_override)
    error_message = "sql_sku_override must be empty (auto) or one of: S0, S1, S2, S3"
  }
}

# Cost guard on the ephemeral RG. Budget is monthly-grain (Azure's smallest);
# fires when accumulated MTD spend on the RG crosses the threshold percentage.
# Realistic numbers at our run size: a normal 60-min run is well under $1; a
# forgotten validation gate that lives 8 hours is ~$5; multiple stuck/runaway
# RGs in one month would compound. Empty -BudgetAlertEmails skips the budget
# entirely (default), so it's opt-in until a real email goes here.
variable "budget_alert_amount" {
  type        = number
  description = "Monthly budget cap for the ephemeral RG (USD). Notifies when actual MTD spend exceeds budget_alert_threshold_pct."
  default     = 50
}

variable "budget_alert_threshold_pct" {
  type        = number
  description = "Percentage of budget_alert_amount that triggers the email notification (0-100)."
  default     = 80
  validation {
    condition     = var.budget_alert_threshold_pct > 0 && var.budget_alert_threshold_pct <= 1000
    error_message = "budget_alert_threshold_pct must be between 1 and 1000."
  }
}

variable "budget_alert_emails" {
  type        = list(string)
  description = "Recipients of the budget alert. Empty list disables the budget resource entirely."
  default     = []
}
