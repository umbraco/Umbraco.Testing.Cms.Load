variable "resource_group_location" {
  type    = string
  default = "West Europe"
}

variable "resource_group_name" {
  type    = string
  default = "andreas-load-testing-rg"
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