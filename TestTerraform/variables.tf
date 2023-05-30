# These are the umbraco versions being load tested. You can update, add more or delete these if you want to test other versions
variable "umbraco_cms_versions" {
  type = map(any)
  default = {
    version_10_5_1 = {
      dotnet_version  = "v6.0"
      umbraco_version = "10.5.1"
    }
    version_11_3_1 = {
      dotnet_version  = "v7.0"
      umbraco_version = "11.3.1"
    }
  }
}

#variable "test_map" {
#  type = map(object({
#    dotnet_version = string
#    umbraco_version = string
#  })) 
#}