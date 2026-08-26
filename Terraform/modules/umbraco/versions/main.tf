locals {
  # "17.0.0__Standard__Default" -> "17-0-0-standard-default"
  case_suffix = replace(lower(var.test_case_id), "/[._]+/", "-")

  # Predicted hostname; reading default_hostname here would self-cycle.
  app_service_name             = "${var.resource_name_prefix}-appservice-${local.case_suffix}"
  app_service_hostname_predict = "${local.app_service_name}.azurewebsites.net"

  case_tags = merge(var.common_tags, {
    test_case_id    = var.test_case_id
    umbraco_version = var.umbraco_version
    scenario        = var.scenario
  })

  # Hash the scenario AdditionalSetup tree so deploy_umbraco re-runs on any overlay edit.
  # The validator allows scenarios to omit the folder entirely; try() returns []
  # when the directory doesn't exist, producing a stable empty-set hash.
  scenario_overlay_dir   = "${path.root}/../loadtests/scenarios/${var.scenario}/AdditionalSetup"
  scenario_overlay_files = try(sort(tolist(fileset(local.scenario_overlay_dir, "**"))), [])
  scenario_overlay_hash = sha256(join("|", [
    for f in local.scenario_overlay_files : "${f}=${filesha256("${local.scenario_overlay_dir}/${f}")}"
  ]))
}

# Database - joins the per-tier Elastic Pool. The Cloud model is one shared
# pool per plan; per-DB DTU cap is enforced by the pool's per_database_settings.
# Setting sku_name = "ElasticPool" is the documented way to attach to a pool.
resource "azurerm_mssql_database" "database" {
  name            = "${var.resource_name_prefix}-db-${local.case_suffix}"
  server_id       = var.sql_server_id
  collation       = "SQL_Latin1_General_CP1_CI_AS"
  sku_name        = "ElasticPool"
  elastic_pool_id = var.elastic_pool_id
  tags            = local.case_tags
}

# App Service
resource "azurerm_windows_web_app" "app_service" {
  name                = local.app_service_name
  location            = var.resource_group_location
  resource_group_name = var.resource_group_name
  service_plan_id     = var.service_plan_id
  tags                = local.case_tags

  # Catch the 60-char Azure App Service name cap with a clear message instead
  # of a generic Azure 400 deep in apply. Long Umbraco prerelease tags + long
  # prefixes can blow this budget; shorten one of (prefix, version, scenario).
  lifecycle {
    precondition {
      condition     = length(local.app_service_name) <= 60
      error_message = "Computed App Service name '${local.app_service_name}' is ${length(local.app_service_name)} chars (Azure cap is 60). Shorten the prefix, Umbraco version, or scenario name."
    }
    # Charset as well as length - an invalid char otherwise surfaces as a generic
    # Azure 400 mid-apply. prepare-test-cases.ps1 rejects these at validation;
    # this is the backstop for a hand-written tfvars run.
    precondition {
      condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", local.app_service_name))
      error_message = "Computed App Service name '${local.app_service_name}' contains characters Azure rejects. Allowed: lowercase letters, digits and hyphens (not leading/trailing). Check the Umbraco version and scenario name."
    }
  }

  # Force HTTPS; disable basic-auth deploy paths; disable session affinity so load
  # tests round-robin across plan instances.
  https_only                                     = true
  ftp_publish_basic_authentication_enabled       = false
  webdeploy_publish_basic_authentication_enabled = false
  client_affinity_enabled                        = false

  site_config {
    application_stack {
      current_stack  = "dotnet"
      dotnet_version = var.dotnet_version
    }
  }

  # Overlay wins on key collision.
  app_settings = merge(
    {
      "Umbraco__CMS__Unattended__InstallUnattended"   = "true"
      "Umbraco__CMS__Unattended__UnattendedUserName"  = "Load Test Admin"
      "Umbraco__CMS__Unattended__UnattendedUserEmail" = "loadtest@example.invalid"
      # Hardcoded so anyone on the team can log into the backoffice with known creds.
      "Umbraco__CMS__Unattended__UnattendedUserPassword" = "LoadTest123!"

      # Pre-built artifacts are zip-deployed via `az webapp deployment source config-zip`,
      # so Oryx/Kudu shouldn't try to build again. False shaves a few seconds per deploy
      # and avoids edge cases where Oryx misidentifies the artifact.
      "SCM_DO_BUILD_DURING_DEPLOYMENT" = "false"
      # Keep the Microsoft namespace at Umbraco's default (Warning). Information
      # emits per-request ASP.NET + per-SQL EF Core logs, which under seeding +
      # concurrent load balloon the Serilog file to hundreds of MB — distorting
      # measurements, pressuring the App Service local disk, and making the single
      # file sink a prime suspect for backoffice 500s under load (it also makes the
      # backoffice log viewer refuse to open the file). Raise deliberately when
      # debugging a specific run, not as a standing default.
      "Serilog__MinimumLevel__Override__Microsoft" = "Warning"
      # Same reasoning as the Microsoft override above, different offender: every
      # backoffice OAuth cycle (authorize/token/revoke/end_session) logs several
      # Information-level lines here (matched endpoint, extracted/validated
      # request, JSON response) — confirmed via a real run's trace log to be ~88%
      # of total log volume under backoffice load, dwarfing the Microsoft override.
      "Serilog__MinimumLevel__Override__OpenIddict" = "Warning"
      # Fires once per content save/publish: "Notifications can not be sent, no
      # site URL is set" — this environment has no absolute site URL configured
      # and no notification consumers (no one needs the load test to email
      # anyone), so the warning is expected and harmless, but it fired 4452
      # times in one run (48% of the post-Microsoft/OpenIddict log volume).
      # Deliberately narrow (this handler only, not a broad namespace) so it
      # doesn't hide other Umbraco.Cms.Core.Events warnings. If backoffice email
      # notifications are ever exercised by a test, configure the site URL
      # instead of raising this back down.
      "Serilog__MinimumLevel__Override__Umbraco.Cms.Core.Events.UserNotificationsHandler" = "Error"

      "Umbraco.Cms.TestDataSeeder__Options__Enabled"      = "true"
      "Umbraco.Cms.TestDataSeeder__Options__Preset"       = var.seeder_preset
      "Umbraco.Cms.TestDataSeeder__Options__DomainSuffix" = local.app_service_hostname_predict
      # Pin Faker's PRNG to a fixed seed so every pipeline run generates
      # byte-identical seeded data (same page titles, word counts, content
      # tree shape). Without this, Faker defaults to current-time seeding,
      # baking a layer of cross-run variance into measurements that's
      # indistinguishable from real perf regressions. With the seed pinned,
      # any cross-run delta is attributable to code/infra changes only.
      # The exact value doesn't matter — any constant works.
      "Umbraco.Cms.TestDataSeeder__Options__FakerSeed" = "42"
    },
    var.app_settings_overlay
  )

  connection_string {
    name = "umbracoDbDSN"
    type = "SQLAzure"
    value = join(";", [
      "Server=tcp:${var.sql_server_fqdn},1433",
      "Initial Catalog=${azurerm_mssql_database.database.name}",
      "Persist Security Info=False",
      "User ID=${var.admin_login}@${var.sql_server_name}",
      "Password=${var.admin_password}",
      "MultipleActiveResultSets=False",
      "Encrypt=True",
      "TrustServerCertificate=False",
      "Connection Timeout=120",
    ])
  }
}

# Runs the script to build, publish, and deploy Umbraco CMS.
resource "null_resource" "deploy_umbraco" {
  triggers = {
    umbraco_version       = var.umbraco_version
    app_service_id        = azurerm_windows_web_app.app_service.id
    scenario              = var.scenario
    scenario_overlay_hash = local.scenario_overlay_hash
    # The command below passes -SeederPreset directly, so a preset change must
    # re-run the deploy/seed. Without this the seeder never re-executes against
    # the new preset on a persisted backend (no-op under the ephemeral RG model,
    # where every run recreates this resource — but correct either way).
    seeder_preset = var.seeder_preset
    # Same reasoning, for the appsettings overlay: a re-apply onto reused state
    # with a changed overlay must also re-run deploy/seed, or the app keeps the
    # stale settings until something else happens to retrigger it.
    app_settings_hash = sha256(jsonencode(var.app_settings_overlay))
    # Referenced here purely to establish the implicit dependency on the
    # parent module's firewall rule (Umbraco hits SQL on first boot).
    firewall_rule_id = var.sql_firewall_rule_dependency
  }

  provisioner "local-exec" {
    # SP credentials inherit from the parent terraform process env (set on the
    # pipeline's Terraform Apply task). Not declared here on purpose - putting
    # sensitive vars in `environment = {}` makes terraform suppress local-exec
    # output, which hides the install script's progress.
    #
    # SeederResultPath is a per-test-case JSON file under <repo>/.seeder-results
    # (path.root is the Terraform working dir = $(System.DefaultWorkingDirectory)/Terraform,
    # so '../' resolves to the pipeline workspace root). The load-test job reads
    # this file via the same path to surface seeder duration in the published metrics.
    # Module-relative: local-exec's cwd is Terraform's invocation dir, not this
    # module's, so a repo-relative path only works while the layout holds.
    command     = "${path.module}/../scripts/install-umbraco-cms-on-appservice.ps1 -ResourceGroupName \"${var.resource_group_name}\" -AppServiceName \"${azurerm_windows_web_app.app_service.name}\" -AppServiceHostname \"${azurerm_windows_web_app.app_service.default_hostname}\" -UmbracoVersion \"${var.umbraco_version}\" -Scenario \"${var.scenario}\" -SeederPreset \"${var.seeder_preset}\" -SeederResultPath \"${path.root}/../.seeder-results/${var.test_case_id}.json\""
    interpreter = ["pwsh", "-Command"]
  }

  depends_on = [
    azurerm_windows_web_app.app_service,
    azurerm_mssql_database.database,
  ]
}
