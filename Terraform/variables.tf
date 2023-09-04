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
  type = map(object({
    dotnet_version = string
    umbraco_version = string
  })) 
}