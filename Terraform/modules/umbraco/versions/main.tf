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
  scenario_overlay_dir   = "${path.root}/../loadtests/scenarios/${var.scenario}/AdditionalSetup"
  scenario_overlay_files = sort(tolist(fileset(local.scenario_overlay_dir, "**")))
  scenario_overlay_hash = sha256(join("|", [
    for f in local.scenario_overlay_files : "${f}=${filesha256("${local.scenario_overlay_dir}/${f}")}"
  ]))
}

# SQL server
resource "azurerm_mssql_server" "sql_server" {
  name                         = "${var.resource_name_prefix}-sqlserver-${local.case_suffix}"
  resource_group_name          = var.resource_group_name
  location                     = var.resource_group_location
  version                      = "12.0"
  administrator_login          = var.admin_login
  administrator_login_password = var.admin_password
  minimum_tls_version          = "1.2"
  tags                         = local.case_tags
}

# Allow all Azure services to access the SQL server.
resource "azurerm_mssql_firewall_rule" "allow_azure_services" {
  name             = "AllowAzureServices-${local.case_suffix}"
  server_id        = azurerm_mssql_server.sql_server.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

# Database
resource "azurerm_mssql_database" "database" {
  name        = "${var.resource_name_prefix}-db-${local.case_suffix}"
  server_id   = azurerm_mssql_server.sql_server.id
  collation   = "SQL_Latin1_General_CP1_CI_AS"
  max_size_gb = var.sql_max_size_gb
  sku_name    = var.sql_sku
  tags        = local.case_tags
}

# App Service
resource "azurerm_windows_web_app" "app_service" {
  name                = local.app_service_name
  location            = var.resource_group_location
  resource_group_name = var.resource_group_name
  service_plan_id     = var.service_plan_id
  tags                = local.case_tags

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
      "Umbraco.Core.LocalTempStorage"          = "EnvironmentTemp"
      "Umbraco.Examine.LuceneDirectoryFactory" = "Examine.LuceneEngine.Directories.SyncTempEnvDirectoryFactory, Examine"

      "Umbraco__CMS__Unattended__InstallUnattended"   = "true"
      "Umbraco__CMS__Unattended__UnattendedUserName"  = "Load Test Admin"
      "Umbraco__CMS__Unattended__UnattendedUserEmail" = "loadtest@example.invalid"
      # Hardcoded so anyone on the team can log into the backoffice with known creds.
      "Umbraco__CMS__Unattended__UnattendedUserPassword" = "LoadTest123!"

      "SCM_DO_BUILD_DURING_DEPLOYMENT"             = "true"
      "Serilog__MinimumLevel__Override__Microsoft" = "Information"

      "Umbraco.Cms.TestDataSeeder__Options__Enabled"      = "true"
      "Umbraco.Cms.TestDataSeeder__Options__Preset"       = var.seeder_preset
      "Umbraco.Cms.TestDataSeeder__Options__DomainSuffix" = local.app_service_hostname_predict
    },
    var.app_settings_overlay
  )

  connection_string {
    name = "umbracoDbDSN"
    type = "SQLAzure"
    value = join(";", [
      "Server=tcp:${azurerm_mssql_server.sql_server.fully_qualified_domain_name},1433",
      "Initial Catalog=${azurerm_mssql_database.database.name}",
      "Persist Security Info=False",
      "User ID=${azurerm_mssql_server.sql_server.administrator_login}@${azurerm_mssql_server.sql_server.name}",
      "Password=${azurerm_mssql_server.sql_server.administrator_login_password}",
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
  }

  provisioner "local-exec" {
    # SP credentials inherit from the parent terraform process env (set on the
    # pipeline's Terraform Apply task). Not declared here on purpose - putting
    # sensitive vars in `environment = {}` makes terraform suppress local-exec
    # output, which hides the install script's progress.
    command     = "./modules/umbraco/scripts/install-umbraco-cms-on-appservice.ps1 -ResourceGroupName \"${var.resource_group_name}\" -AppServiceName \"${azurerm_windows_web_app.app_service.name}\" -AppServiceHostname \"${azurerm_windows_web_app.app_service.default_hostname}\" -UmbracoVersion \"${var.umbraco_version}\" -Scenario \"${var.scenario}\" -SeederPreset \"${var.seeder_preset}\""
    interpreter = ["pwsh", "-Command"]
  }

  # Umbraco hits SQL on first boot; firewall rule must exist first.
  depends_on = [
    azurerm_windows_web_app.app_service,
    azurerm_mssql_firewall_rule.allow_azure_services,
  ]
}
