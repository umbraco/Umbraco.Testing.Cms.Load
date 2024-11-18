variable "resource_group_location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "resource_name_prefix" {
  description = "This name will prefix all the created resources"
  validation {
    condition     = can(regex("^[0-9a-z]([-0-9a-z]{0,100}[0-9a-z])?$", var.resource_name_prefix))
    error_message = "The prefix can contain only lowercase letters, numbers, and '-', but can't start or end with '-' or have more than 100 characters."
  }
}

variable "umbraco_cms_versions" {
  type = map(object({
    dotnet_version  = string
    umbraco_version = string
  }))
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

variable "app_service_plan_sku" {
  type = string
}