locals {
  tiers_in_use = toset([for v in var.test_cases : v.tier])

  # Azure SQL admin login must start with a letter; prefix one since random_string can start with a digit.
  sql_admin_login = "u${random_string.admin_login.result}"

  # Per-tier App Service Plan SKU, with the queue-time override applied if set.
  # Computed once here (not inline on the resource below) so output.tf can
  # reference the same value instead of re-deriving the override logic - a
  # resource provisioned with one value and metadata reporting a recomputed
  # one would silently disagree if the two copies ever drifted.
  tier_app_sku = {
    for t in local.tiers_in_use :
    t => var.app_sku_override != "" ? var.app_sku_override : var.tier_specs[t].app_sku
  }

  # Per-DB DTU cap per tier, with the queue-time override applied if set.
  # The override lets a run size SQL independently of the app tier to isolate
  # which side is the bottleneck.
  tier_db_dtu = {
    for t in local.tiers_in_use :
    t => var.pool_dtu_override != 0 ? var.pool_dtu_override : var.tier_specs[t].dtu_max
  }

  # Pool eDTU capacity: smallest valid Standard pool that can hold a DB at the
  # tier cap. Standard pool minimum is 50; bump to 100 when the per-DB cap
  # requires it. Beyond 100 the next valid Standard step is 200.
  tier_pool_dtu = {
    for t, db_dtu in local.tier_db_dtu :
    t => db_dtu <= 50 ? 50 : db_dtu <= 100 ? 100 : 200
  }

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

  # Start of current month, in UTC. In the normal ephemeral model the RG (and
  # this budget) are created fresh every run, so start_date is always the
  # current month at create time — no roll-forward needed.
  #
  # end_date is set explicitly ~10 years out. azurerm provider defaults this
  # to start_date + 1 year, which silently disables the budget after 12
  # months from initial apply — easy to miss because Terraform doesn't drift-
  # detect a "budget that no longer monitors anything". Pushing it ~decade out
  # keeps the budget active even if state is ever reused across a year boundary.
  #
  # NOTE: time_period is in ignore_changes (see lifecycle below), so on an
  # in-place re-apply the window is NOT refreshed. That's intentional — it
  # avoids a perpetual timestamp()-driven diff — and harmless given the fresh
  # create per run plus the decade-long end_date.
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
# Override lets a run size the app independently of the tier (paired with
# pool_dtu_override on the SQL side) to isolate app-vs-SQL bottlenecks.
resource "azurerm_service_plan" "appserviceplan" {
  for_each            = local.tiers_in_use
  name                = "${var.resource_name_prefix}-asp-${lower(each.key)}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  os_type             = "Windows"
  sku_name            = local.tier_app_sku[each.key]
  tags                = merge(local.common_tags, { tier = each.key })
}

# SQL server per tier - hosts the tier's Elastic Pool. One server per tier keeps
# the case-level resource graph identical between same-tier cases (they share
# server + pool) and matches the Cloud model where each plan has its own pool.
resource "azurerm_mssql_server" "sql_server" {
  for_each                     = local.tiers_in_use
  name                         = "${var.resource_name_prefix}-sql-${lower(each.key)}"
  resource_group_name          = azurerm_resource_group.rg.name
  location                     = azurerm_resource_group.rg.location
  version                      = "12.0"
  administrator_login          = local.sql_admin_login
  administrator_login_password = random_password.admin_password.result
  minimum_tls_version          = "1.2"
  tags                         = merge(local.common_tags, { tier = each.key })
}

resource "azurerm_mssql_firewall_rule" "allow_azure_services" {
  for_each         = local.tiers_in_use
  name             = "AllowAzureServices-${lower(each.key)}"
  server_id        = azurerm_mssql_server.sql_server[each.key].id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

# Standard-tier Elastic Pool per tier. Pool eDTU is the smallest valid Standard
# size that can hold a DB at the tier cap; per-DB max DTU equals the cap.
# max_size_gb=50 is the Standard-tier minimum; our test data is well under that,
# so the floor is enough and avoids paying for storage we won't use.
resource "azurerm_mssql_elasticpool" "pool" {
  for_each            = local.tiers_in_use
  name                = "${var.resource_name_prefix}-pool-${lower(each.key)}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  server_name         = azurerm_mssql_server.sql_server[each.key].name
  max_size_gb         = 50
  tags                = merge(local.common_tags, { tier = each.key })

  sku {
    name     = "StandardPool"
    tier     = "Standard"
    capacity = local.tier_pool_dtu[each.key]
  }

  per_database_settings {
    min_capacity = 0
    max_capacity = local.tier_db_dtu[each.key]
  }
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

  sql_server_name              = azurerm_mssql_server.sql_server[each.value.tier].name
  sql_server_id                = azurerm_mssql_server.sql_server[each.value.tier].id
  sql_server_fqdn              = azurerm_mssql_server.sql_server[each.value.tier].fully_qualified_domain_name
  elastic_pool_id              = azurerm_mssql_elasticpool.pool[each.value.tier].id
  sql_firewall_rule_dependency = azurerm_mssql_firewall_rule.allow_azure_services[each.value.tier].id

  seeder_preset = var.seeder_preset
  common_tags   = local.common_tags
}
