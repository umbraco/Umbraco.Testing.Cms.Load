# Replace . with - in umbraco versions. The reason for this is that we can't have . in our naming for resources
locals {
  version_name = replace(var.umbraco_cms_version, ".", "-")
}

# SQL server
resource "azurerm_mssql_server" "msserver" {
  name                         = "${var.resource_name_prefix}-sqlserver-${local.version_name}"
  resource_group_name          = var.resource_group_name
  location                     = var.resource_group_location
  version                      = "12.0"
  administrator_login          = var.admin_login
  administrator_login_password = var.admin_password
  minimum_tls_version          = "1.2"
  # Added a timeout for creating the server because it can sometimes fail and run for 60 min
  # If the msserver isn't created in time, it can be locked in azure. Which makes us unable to delete the rg
  timeouts {
    create = "10m"
  }
}

# Allow all azure services
resource "azurerm_mssql_firewall_rule" "firewallrule" {
  name             = "Allow all azure services-${local.version_name}"
  server_id        = azurerm_mssql_server.msserver.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

# Database
resource "azurerm_mssql_database" "db" {
  name        = "${var.resource_name_prefix}-db-${local.version_name}"
  server_id   = azurerm_mssql_server.msserver.id
  collation   = "SQL_Latin1_General_CP1_CI_AS"
  max_size_gb = 5
  sku_name    = "S0"
}

# App Service
resource "azurerm_windows_web_app" "appservice" {
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
    "Umbraco.Core.MainDom.Lock"                        = "SqlMainDomLock"
    "Umbraco.Core.LocalTempStorage"                    = "EnvironmentTemp"
    "Umbraco.Examine.LuceneDirectoryFactory"           = "Examine.LuceneEngine.Directories.SyncTempEnvDirectoryFactory, Examine"
    "Umbraco__CMS__Unattended__InstallUnattended"      = "true"
    "Umbraco__CMS__Unattended__UnattendedUserName"     = "John Doe"
    "Umbraco__CMS__Unattended__UnattendedUserEmail"    = "admin@admin.admin"
    "Umbraco__CMS__Unattended__UnattendedUserPassword" = "1234567890"
    "SCM_DO_BUILD_DURING_DEPLOYMENT"                   = true
  }

  connection_string {
    name  = "umbracoDbDSN"
    type  = "SQLAzure"
    value = "Server=tcp:${azurerm_mssql_server.msserver.fully_qualified_domain_name},1433;database=${azurerm_mssql_database.db.name};User ID=${azurerm_mssql_server.msserver.administrator_login};Password=${azurerm_mssql_server.msserver.administrator_login_password};Connection Timeout=120;"
  }
}

# Runs the script which creates and deploys a Umbraco CMS with the defined version.
resource "null_resource" "deploy_umbraco_windows_host" {
  provisioner "local-exec" {
    command = "./modules/umbraco/scripts/install-umbraco-cms-on-appservice.ps1 -rgName \"${var.resource_group_name}\" -appserviceName \"${azurerm_windows_web_app.appservice.name}\" -appserviceHostname \"${azurerm_windows_web_app.appservice.default_hostname}\" -umbracoVersion \"${var.umbraco_cms_version}\" -client_id \"${var.client_id}\" -client_secret \"${var.client_secret}\" -tenant_id \"${var.tenant_id}\""
    // Remember to change to "pwsh" for the pipeline
    // "Powershell" for local
    interpreter = ["pwsh", "-Command"]
  }
  depends_on = [azurerm_windows_web_app.appservice]
}