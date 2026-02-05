# Umbraco Load Testing

Load testing starter kit for Umbraco CMS on Azure.

## Usage

### Via Pipeline

1. Create results storage (once):
   ```bash
   az group create -n loadtest-results-rg -l "West Europe"
   az storage account create -n <unique-name> -g loadtest-results-rg -l "West Europe" --sku Standard_LRS
   az storage container create -n loadtest-results --account-name <unique-name>
   ```

2. Create Variable Group `UmbracoLoadTest` in Azure DevOps:
   ```
   resultsStorageAccountName: <your-storage-account-name>
   firstDotNetVersion: v8.0
   firstUmbracoVersion: 14.3.0
   secondDotNetVersion: v9.0
   secondUmbracoVersion: 15.1.0
   ```

3. Run the pipeline, select settings (SKU, users, duration)

4. View results in Azure Portal → Load Testing

### Local

1. Copy and configure Terraform variables:
   ```bash
   cd terraform
   cp terraform.tfvars.example terraform.tfvars
   ```

2. Edit `terraform.tfvars` with your settings:
   ```hcl
   resource_name_prefix = "your-prefix"
   results_storage_account_name = "<your-storage-account-name>"
   umbraco_cms_versions = {
     "v14" = { dotnet_version = "v8.0", umbraco_version = "14.3.0" }
     "v15" = { dotnet_version = "v9.0", umbraco_version = "15.1.0" }
   }
   ```

3. Deploy infrastructure:
   ```bash
   az login
   terraform init && terraform apply
   ```

4. Build and run tests:
   ```bash
   cd ../loadtests
   npm install && npm run build
   k6 run dist/main.js -e HOST_NAME=<app-service-url>
   ```

Note: Add scenarios to `loadtests/src/main.js` before running tests.

## Structure

```
LoadTestSetup/
├── terraform/           # Azure infrastructure
├── loadtests/src/       # Test code (JavaScript)
├── azure-pipeline.yml   # CI/CD pipeline
└── docs/                # Design document
```

## More Info

See [docs/DESIGN_DOCUMENT.md](docs/DESIGN_DOCUMENT.md)
