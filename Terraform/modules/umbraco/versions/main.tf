# Replace . with - in Umbraco versions for resource naming
locals {
  short_version_name = split("-", var.umbraco_cms_version)[0]
  version_name       = replace(local.short_version_name, ".", "-")
}

# SQL Server
resource "azurerm_mssql_server" "sql_server" {
  name                         = "${var.resource_name_prefix}-sqlserver-${local.version_name}"
  resource_group_name          = var.resource_group_name
  location                     = var.resource_group_location
  version                      = "12.0"
  administrator_login          = var.admin_login
  administrator_login_password = var.admin_password
  minimum_tls_version          = "1.2"

  timeouts {
    create = "7m"
  }
}

# Firewall rule to allow Azure services
resource "azurerm_mssql_firewall_rule" "allow_azure_services" {
  name             = "AllowAzureServices-${local.version_name}"
  server_id        = azurerm_mssql_server.sql_server.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

# SQL Database
resource "azurerm_mssql_database" "database" {
  name        = "${var.resource_name_prefix}-db-${local.version_name}"
  server_id   = azurerm_mssql_server.sql_server.id
  collation   = "SQL_Latin1_General_CP1_CI_AS"
  max_size_gb = var.sql_max_size_gb
  sku_name    = var.sql_sku
}

# Windows App Service
resource "azurerm_windows_web_app" "app_service" {
  name                = "${var.resource_name_prefix}-appservice-${local.version_name}"
  location            = var.resource_group_location
  resource_group_name = var.resource_group_name
  service_plan_id     = var.service_plan_id

  site_config {
    application_stack {
      current_stack  = "dotnet"
      dotnet_version = var.dotnet_version
    }
  }

  app_settings = {
    # Umbraco Azure configuration
    "Umbraco.Core.LocalTempStorage"          = "EnvironmentTemp"
    "Umbraco.Examine.LuceneDirectoryFactory" = "Examine.LuceneEngine.Directories.SyncTempEnvDirectoryFactory, Examine"

    # Unattended installation (test credentials — resources auto-delete after 2h)
    "Umbraco__CMS__Unattended__InstallUnattended"      = "true"
    "Umbraco__CMS__Unattended__UnattendedUserName"     = "John Doe"
    "Umbraco__CMS__Unattended__UnattendedUserEmail"    = "admin@admin.admin"
    "Umbraco__CMS__Unattended__UnattendedUserPassword" = "1234567890"

    # Build settings
    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "true"

    # Logging
    "Serilog__MinimumLevel__Override__Microsoft" = "Information"

    # Data seeder configuration
    # v17+: PerformanceTestDataSeeder (full load testing support with member auth, contact forms)
    # v13-16: DummyDataSeeder (basic content seeding)
    # Both are configured — only the installed package will read its settings
    "PerformanceTestDataSeeder__Options__Enabled"            = "true"
    "PerformanceTestDataSeeder__Options__Preset"             = var.seeder_preset
    "PerformanceTestDataSeeder__Options__SkipContentDomains" = "true"
    "DummyDataSeeder__Options__Enabled"                      = "true"
    "DummyDataSeeder__Options__Preset"                       = var.seeder_preset
  }

  connection_string {
    name  = "umbracoDbDSN"
    type  = "SQLAzure"
    value = "Server=tcp:${azurerm_mssql_server.sql_server.fully_qualified_domain_name},1433;Initial Catalog=${azurerm_mssql_database.database.name};Persist Security Info=False;User ID=${azurerm_mssql_server.sql_server.administrator_login}@${azurerm_mssql_server.sql_server.name};Password=${azurerm_mssql_server.sql_server.administrator_login_password};MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=120;"
  }
}

# Deploy Umbraco CMS via PowerShell script
resource "null_resource" "deploy_umbraco" {
  # Re-run the provisioner whenever the version or target app service changes.
  # Without this, `terraform apply` after bumping umbraco_cms_version would no-op
  # because null_resource has no inputs of its own that Terraform can diff.
  triggers = {
    umbraco_version = var.umbraco_cms_version
    app_service_id  = azurerm_windows_web_app.app_service.id
  }

  provisioner "local-exec" {
    command = "./modules/umbraco/scripts/install-umbraco-cms-on-appservice.ps1 -rgName \"${var.resource_group_name}\" -appserviceName \"${azurerm_windows_web_app.app_service.name}\" -appserviceHostname \"${azurerm_windows_web_app.app_service.default_hostname}\" -umbracoVersion \"${var.umbraco_cms_version}\" -client_id \"${var.client_id}\" -client_secret \"${var.client_secret}\" -tenant_id \"${var.tenant_id}\""
    # Use "pwsh" for CI pipeline, "PowerShell" for local Windows
    interpreter = ["pwsh", "-Command"]
  }

  # Wait for the firewall rule too — Umbraco's first-boot startup hits SQL,
  # and "Allow Azure services" must be in place before the connection succeeds.
  depends_on = [
    azurerm_windows_web_app.app_service,
    azurerm_mssql_firewall_rule.allow_azure_services,
  ]
}
