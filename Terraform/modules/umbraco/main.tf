locals {
  tiers_in_use = toset([for v in var.test_cases : v.tier])

  # Azure SQL admin login must start with a letter; prefix one since random_string can start with a digit.
  sql_admin_login = "u${random_string.admin_login.result}"

  common_tags = {
    project    = "umbraco-loadtest"
    managed_by = "terraform"
    build_id   = var.build_id
  }
}

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.resource_group_location
  tags     = local.common_tags
}

# Cost guard: monthly budget on the ephemeral RG that emails when MTD spend
# crosses the threshold percentage. Skipped entirely when budget_alert_emails
# is empty (the default) so it stays opt-in.
#
# Trade-offs:
# * Monthly grain is Azure's smallest budget window — there's no per-run /
#   per-hour. A single run accruing $4 won't fire (well below 80% × $50);
#   the alert protects against MULTIPLE forgotten gates compounding within
#   a billing month, OR a runaway loop.
# * The budget resource itself is destroyed when terraform destroy runs at
#   end-of-pipeline cleanup, so an "orphaned" RG that survives cleanup also
#   loses its budget — at which point you'd want a subscription-scope budget
#   instead. Out of scope here; this RG-scope budget covers the normal case.
resource "azurerm_consumption_budget_resource_group" "ephemeral" {
  count             = length(var.budget_alert_emails) > 0 ? 1 : 0
  name              = "${var.resource_group_name}-budget"
  resource_group_id = azurerm_resource_group.rg.id

  amount     = var.budget_alert_amount
  time_grain = "Monthly"

  # Start of current month, in UTC. formatdate keeps it stable across re-applies
  # within the same month; a re-apply in a new month will roll the start date
  # forward, which is the desired behavior for monthly grain.
  #
  # end_date is set explicitly ~10 years out. azurerm provider defaults this
  # to start_date + 1 year, which silently disables the budget after 12
  # months from initial apply — easy to miss because Terraform doesn't drift-
  # detect a "budget that no longer monitors anything". Pushing it ~decade
  # out makes the time window long enough that re-applies (which always
  # happen on each pipeline run) will refresh start_date well before
  # end_date matters.
  time_period {
    start_date = formatdate("YYYY-MM-01'T'00:00:00'Z'", timestamp())
    end_date   = formatdate("YYYY-MM-01'T'00:00:00'Z'", timeadd(timestamp(), "87600h"))
  }

  notification {
    enabled        = true
    threshold      = var.budget_alert_threshold_pct
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = var.budget_alert_emails
  }

  lifecycle {
    # start_date drifts via timestamp() on every plan; ignoring its diff
    # avoids spurious "in-place update" plans that don't change semantics.
    ignore_changes = [time_period]
  }
}

resource "random_string" "admin_login" {
  length  = 15
  special = false
}

# SQL admin password. Azure SQL needs 3 of 4 char categories; force upper+lower+numeric.
resource "random_password" "admin_password" {
  length      = 24
  special     = false
  min_upper   = 1
  min_lower   = 1
  min_numeric = 1
}

# One plan per tier in use; same-tier cases share it (only one app hot at a time).
resource "azurerm_service_plan" "appserviceplan" {
  for_each            = local.tiers_in_use
  name                = "${var.resource_name_prefix}-asp-${lower(each.key)}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  os_type             = "Windows"
  sku_name            = var.tier_specs[each.key].app_sku
  tags                = merge(local.common_tags, { tier = each.key })
}

# Azure Load Testing resource lives in a long-lived RG (see scripts/ensure-history-infra.ps1).

module "versions" {
  for_each = var.test_cases
  source   = "./versions"

  resource_name_prefix    = var.resource_name_prefix
  resource_group_name     = azurerm_resource_group.rg.name
  resource_group_location = azurerm_resource_group.rg.location
  service_plan_id         = azurerm_service_plan.appserviceplan[each.value.tier].id

  test_case_id         = each.key
  dotnet_version       = each.value.dotnet_version
  umbraco_version      = each.value.umbraco_version
  scenario             = each.value.scenario
  app_settings_overlay = each.value.app_settings_overlay

  admin_login    = local.sql_admin_login
  admin_password = random_password.admin_password.result
  # sql_sku_override lets the run size SQL independently of the App Service tier
  # (e.g. Standard app + S2 SQL) to isolate which side is the bottleneck.
  # Empty override falls back to each tier's built-in pairing from tiers.json.
  sql_sku         = var.sql_sku_override != "" ? var.sql_sku_override : var.tier_specs[each.value.tier].sql_sku
  sql_max_size_gb = var.tier_specs[each.value.tier].sql_max_size_gb

  seeder_preset = var.seeder_preset
  common_tags   = local.common_tags
}
