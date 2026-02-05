# Per-Version Resources: SQL Server, Database, and App Service for each Umbraco version

locals {
  short_version_name = split("-", var.umbraco_cms_version)[0]
  version_name       = replace(local.short_version_name, ".", "-")
}

# SQL Server (one per version for isolation)
resource "azurerm_mssql_server" "msserver" {
  name                         = "${var.resource_name_prefix}-sqlserver-${local.version_name}"
  resource_group_name          = var.resource_group_name
  location                     = var.resource_group_location
  version                      = "12.0"
  administrator_login          = var.admin_login
  administrator_login_password = var.admin_password
  minimum_tls_version          = "1.2"
  tags                         = merge(var.tags, { UmbracoVersion = var.umbraco_cms_version })

  timeouts {
    create = "7m"
  }
}

# Allow Azure services to access SQL Server
resource "azurerm_mssql_firewall_rule" "firewallrule" {
  name             = "allow-azure-services-${local.version_name}"
  server_id        = azurerm_mssql_server.msserver.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

resource "azurerm_mssql_database" "db" {
  name        = "${var.resource_name_prefix}-db-${local.version_name}"
  server_id   = azurerm_mssql_server.msserver.id
  collation   = "SQL_Latin1_General_CP1_CI_AS"
  max_size_gb = var.sql_max_size_gb
  sku_name    = var.sql_sku
  tags        = merge(var.tags, { UmbracoVersion = var.umbraco_cms_version })
}

# App Service with Umbraco
resource "azurerm_windows_web_app" "appservice" {
  name                = "${var.resource_name_prefix}-appservice-${local.version_name}"
  location            = var.resource_group_location
  resource_group_name = var.resource_group_name
  service_plan_id     = var.service_plan_id
  https_only          = true
  tags                = merge(var.tags, { UmbracoVersion = var.umbraco_cms_version })

  site_config {
    minimum_tls_version = "1.2"
    http2_enabled       = true

    application_stack {
      current_stack  = "dotnet"
      dotnet_version = var.dotnet_version
    }

    health_check_path                 = "/umbraco/healthcheck"
    health_check_eviction_time_in_min = 5
  }

  app_settings = {
    # Performance
    "Umbraco__CMS__Hosting__LocalTempStorageLocation" = "EnvironmentTemp"

    # Unattended install (test credentials - resources auto-delete after 24h)
    "Umbraco__CMS__Unattended__InstallUnattended"      = "true"
    "Umbraco__CMS__Unattended__UnattendedUserName"     = "Load Test Admin"
    "Umbraco__CMS__Unattended__UnattendedUserEmail"    = "admin@admin.admin"
    "Umbraco__CMS__Unattended__UnattendedUserPassword" = "1234567890"
    "Umbraco__CMS__Global__MainDomLock" = "SqlMainDomLock"
    "SCM_DO_BUILD_DURING_DEPLOYMENT"             = true
    "Serilog__MinimumLevel__Override__Microsoft" = "Information"
    "WEBSITE_DYNAMIC_CACHE"                      = "0"
    "WEBSITE_LOCAL_CACHE_OPTION"                 = "OnStorageUnavailability"
  }

  connection_string {
    name  = "umbracoDbDSN"
    type  = "SQLAzure"
    value = "Server=tcp:${azurerm_mssql_server.msserver.fully_qualified_domain_name},1433;Initial Catalog=${azurerm_mssql_database.db.name};Persist Security Info=False;User ID=${azurerm_mssql_server.msserver.administrator_login}@${azurerm_mssql_server.msserver.name};Password=${azurerm_mssql_server.msserver.administrator_login_password};MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=120;"
  }
}

# Deploy Umbraco via PowerShell script
resource "null_resource" "deploy_umbraco_windows_host" {
  provisioner "local-exec" {
    command     = "./modules/umbraco/scripts/install-umbraco-cms-on-appservice.ps1 -rgName \"${var.resource_group_name}\" -appserviceName \"${azurerm_windows_web_app.appservice.name}\" -appserviceHostname \"${azurerm_windows_web_app.appservice.default_hostname}\" -umbracoVersion \"${var.umbraco_cms_version}\" -client_id \"${var.client_id}\" -client_secret \"${var.client_secret}\" -tenant_id \"${var.tenant_id}\""
    interpreter = ["pwsh", "-Command"]
  }

  depends_on = [azurerm_windows_web_app.appservice]
}
