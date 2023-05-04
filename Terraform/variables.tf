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
    version_10_0_0 = {
      version_name    = "v10-0-0"
      dotnet_version  = "v6.0"
      umbraco_version = "10.0.0"
    }
    version_10_5_1 = {
      version_name    = "v10-5-1"
      dotnet_version  = "v6.0"
      umbraco_version = "10.5.1"
    }
    version_11_0_0 = {
      version_name    = "v11-0-0"
      dotnet_version  = "v7.0"
      umbraco_version = "11.0.0"
    }
    version_11_3_1 = {
      version_name    = "v11-3-1"
      dotnet_version  = "v7.0"
      umbraco_version = "11.3.1"
    }
  }
}