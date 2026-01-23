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
  sensitive = true
}

variable "client_secret" {
  type    = string
  default = "empty"
  sensitive = true
}

variable "tenant_id" {
  type    = string
  default = "empty"
  sensitive = true
}

variable "app_service_plan_sku" {
  type = string
  default = "S3"
}

variable "umbraco_cms_versions" {
  type = map(object({
    dotnet_version = string
    umbraco_version = string
  }))
}

variable "seeder_preset" {
  type        = string
  description = "DummyDataSeeder preset (Small, Medium, Large, Massive)"
  default     = "Medium"
  validation {
    condition     = contains(["Small", "Medium", "Large", "Massive"], var.seeder_preset)
    error_message = "seeder_preset must be one of: Small, Medium, Large, Massive"
  }
}