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
}

variable "client_id" {
  type    = string
  default = "empty"
  #sensitive = true
}

variable "client_secret" {
  type    = string
  default = "empty"
  #sensitive = true
}

variable "tenant_id" {
  type    = string
  default = "empty"
  #sensitive = true
}

# These are the umbraco versions being load tested. You can update, add more or delete these if you want to test other versions
variable "umbraco_cms_versions" {
  type = map(any)
  default = {
    version_11_3_1 = {
      version_name    = "v11-3-1"
      dotnet_version  = "v7.0"
      umbraco_version = "11.3.1"
    }
    version_12_0_0rc1 = {
      version_name    = "v12-0-0rc1"
      dotnet_version  = "v7.0"
      umbraco_version = "12.0.0-rc1"
    }
  }
}