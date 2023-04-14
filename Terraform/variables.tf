variable "resource_name_prefix" {
  type        = string
  description = "This name will prefix all the created resources"
}

variable "resource_group_location" {
  type    = string
  default = "West Europe"
}

variable "resource_group_name" {
  type = string
  #default = "az-load-testing-rg"
}

variable "client_id" {
  type = string
  # default = "empty"
  #sensitive = true
}
variable "client_secret" {
  type = string
  # default = "empty"
  #sensitive = true
}
variable "tenant_id" {
  type = string
  # default = "empty"
  #sensitive = true
}

variable "bkstrgrg" {
  type        = string
  description = "The name of the backend storage account resource group"
  default     = "<storage act resource group name>"
}

variable "bkstrgname" {
  type        = string
  description = "The name of the backend storage account"
  default     = "<storage account name>"
}

variable "bkcontainer" {
  type        = string
  description = "The container name for the backend config"
  default     = "<blob storage container name>"
}

variable "bkstrgkey" {
  type        = string
  description = "The access key for the storage account"
  default     = "<storage account key>"
}

variable "umbraco_cms_versions" {
  type = map(any)
  default = {
    version_10 = {
      version_name    = "v10"
      dotnet_version  = "v6.0"
      umbraco_version = "10.3.1"
    }
    version_11 = {
      version_name    = "v11"
      dotnet_version  = "v7.0"
      umbraco_version = "11.3.0"
    }
  }
}