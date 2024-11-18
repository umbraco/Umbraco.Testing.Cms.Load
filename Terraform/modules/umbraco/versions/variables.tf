variable "resource_name_prefix" {
  description = "This name will prefix all the created resources"
}

variable "resource_group_name" {
  description = "Name of the resource group that the app service is gonna be located in"
}

variable "resource_group_location" {
  description = "Location for the Azure resources"
}

variable "service_plan_id" {
  description = "ID of the service plan the App service is gonna use"
}

variable "dotnet_version" {
  type        = string
  description = "The version of dotnet to use"
}

variable "umbraco_cms_version" {
  type        = string
  description = "The version of Umbraco.Cms to add as PackageReference"
}

variable "admin_login" {
  type        = string
  description = "admin login"
}

variable "admin_password" {
  type        = string
  description = "admin password"
}

variable "client_id" {
  type = string
  # sensitive = true
}

variable "client_secret" {
  type = string
  # sensitive = true
}

variable "tenant_id" {
  type = string
  # sensitive = true
}