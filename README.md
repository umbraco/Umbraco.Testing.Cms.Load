# Umbraco Load Testing Infrastructure

Automated infrastructure for load testing multiple Umbraco CMS versions on Azure using Terraform and Azure Pipelines.

## Overview

This project provisions isolated Azure environments for each Umbraco version, seeds them with test data using [DummyDataSeeder](https://github.com/AndyButland/UmbracoDummyDataSeeder), and runs JMeter load tests via Azure Load Test service.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                              Azure Resource Group                                 │
├──────────────────────────────────────────────────────────────────────────────────┤
│  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐      │
│  │ App Service   │  │ App Service   │  │ App Service   │  │ App Service   │      │
│  │ (Umbraco 14)  │  │ (Umbraco 15)  │  │ (Umbraco 16)  │  │ (Umbraco 17)  │      │
│  └───────┬───────┘  └───────┬───────┘  └───────┬───────┘  └───────┬───────┘      │
│          │                  │                  │                  │              │
│  ┌───────▼───────┐  ┌───────▼───────┐  ┌───────▼───────┐  ┌───────▼───────┐      │
│  │ SQL Database  │  │ SQL Database  │  │ SQL Database  │  │ SQL Database  │      │
│  └───────────────┘  └───────────────┘  └───────────────┘  └───────────────┘      │
│                                                                                   │
│  ┌───────────────────────────────────────────────────────────────────────────┐   │
│  │                        Shared App Service Plan                             │   │
│  └───────────────────────────────────────────────────────────────────────────┘   │
│  ┌───────────────────────────────────────────────────────────────────────────┐   │
│  │                           Azure Load Test                                  │   │
│  └───────────────────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- Azure subscription with appropriate permissions
- Azure DevOps organization with:
  - Service connection to Azure (`terraform-umbraco-load-testing-az-serviceconnection`)
  - Variable group with Umbraco versions to test
- Terraform >= 1.3.9
- PowerShell Core (pwsh)

## Project Structure

```
LoadTests/
├── azure-pipeline.yml           # Main CI/CD pipeline
├── LoadTestVersions.yaml        # Azure Load Test configuration
├── README.md
│
├── templates/
│   └── load-test-job.yml        # Reusable pipeline template
│
├── loadtests/
│   └── JmeterTest.jmx           # JMeter test plan
│
└── Terraform/
    ├── main.tf                  # Root module
    ├── variables.tf             # Input variables
    ├── output.tf                # Output values
    ├── terraform.tfvars.example # Example configuration
    │
    └── modules/umbraco/
        ├── main.tf              # Resource group, App Service Plan, Load Test
        ├── variables.tf
        ├── output.tf
        │
        ├── scripts/
        │   └── install-umbraco-cms-on-appservice.ps1
        │
        └── versions/            # Per-version resources
            ├── main.tf          # SQL Server, Database, App Service
            ├── variables.tf
            └── output.tf
```

## Configuration

### Pipeline Parameters

| Parameter | Description | Default | Options |
|-----------|-------------|---------|---------|
| `appServicePlanSku` | App Service Plan tier | S3 | S1, S2, S3 |
| `sqlSku` | SQL Database tier | S0 | S0, S1, S2 |
| `sqlMaxSizeGb` | SQL Database max size | 5 | 2, 5, 10, 20 |
| `azureRegion` | Azure region | West Europe | West Europe, North Europe, East US, West US 2 |
| `prefix` | Resource name prefix | umbraco-azure-load-test-pipeline | - |
| `userAmount` | Virtual users for load test | 100 | 50, 100, 150, 200, 250, 300 |
| `seederPreset` | Data seeding volume | Medium | Small, Medium, Large, Massive |

### Version Configuration

Versions are configured via Azure DevOps variable groups:

| Variable | Description | Example |
|----------|-------------|---------|
| `firstDotNetVersion` | .NET version for first test | v8.0 |
| `firstUmbracoVersion` | Umbraco version for first test | 14.3.0 |
| `secondDotNetVersion` | .NET version for second test | v9.0 |
| `secondUmbracoVersion` | Umbraco version for second test | 15.1.0 |
| `thirdDotNetVersion` | .NET version for third test | v9.0 |
| `thirdUmbracoVersion` | Umbraco version for third test | 16.0.0 |
| `fourthDotNetVersion` | .NET version for fourth test | v9.0 |
| `fourthUmbracoVersion` | Umbraco version for fourth test | 17.0.0 |

## Usage

### Running via Azure Pipelines

1. Configure your Azure DevOps variable group with the Umbraco versions to test
2. Run the pipeline manually from Azure DevOps
3. Select desired parameters (SKU, user count, etc.)
4. Wait for infrastructure provisioning and load tests to complete
5. Review results in Azure Load Test
6. Approve or reject resource cleanup within 24 hours

### Running Terraform Locally

```bash
cd Terraform

# Initialize
terraform init

# Copy and configure variables
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

# Plan
terraform plan

# Apply
terraform apply
```

## Pipeline Workflow

```
1. Check Resource Group     ─► Does it already exist?
                               │
2. Format Versions          ─► Convert variables to Terraform JSON
                               │
3. Terraform Plan           ─► Preview infrastructure changes
                               │
4. Terraform Apply          ─► Provision Azure resources
                               │
5. Deploy Umbraco           ─► Install CMS on each App Service
                               │
6. Seed Data                ─► DummyDataSeeder populates content
                               │
7. Run Load Tests           ─► Sequential JMeter tests per version
                               │
8. Manual Validation        ─► 24h window to keep resources
                               │
9. Cleanup                  ─► Delete resource group if rejected
```

## DummyDataSeeder Presets

| Preset | Documents | Media | Members | Approx. Time |
|--------|-----------|-------|---------|--------------|
| Small | ~100 | ~50 | ~20 | 2-5 min |
| Medium | ~500 | ~200 | ~100 | 5-15 min |
| Large | ~2000 | ~500 | ~500 | 15-30 min |
| Massive | ~10000 | ~2000 | ~2000 | 30-60 min |

## Load Test Configuration

The JMeter test plan (`loadtests/JmeterTest.jmx`) tests:

- **Frontend Homepage**: `GET /` - Tests the public website with seeded content
- **Umbraco Backoffice**: `GET /umbraco/` - Tests the backoffice login page
- **Seeder Status API**: `GET /umbraco/api/seederstatus/status` - Health check endpoint

Test parameters:
- Duration: 300 seconds (5 minutes)
- Ramp-up: 150 seconds
- Concurrent pool: 6 connections
- Connect timeout: 5 seconds
- Response timeout: 30 seconds

## Outputs

After Terraform apply, the following outputs are available:

| Output | Description |
|--------|-------------|
| `hostnames` | List of App Service hostnames |
| `cms_versions` | List of deployed Umbraco versions |
| `app_service_names` | List of App Service resource names |

## Troubleshooting

### Common Issues

**SQL Server creation timeout**
- The 7-minute timeout may not be enough in busy regions
- Solution: Re-run the pipeline or increase timeout in `versions/main.tf`

**Seeder not completing**
- Large presets can take up to 60 minutes
- Check seeder status: `https://<hostname>/umbraco/api/seederstatus/status`

**Template version mismatch**
- Ensure Umbraco template version matches CMS version
- Pre-release versions require NuGet sources (automatically configured)

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test locally with `terraform validate`
5. Submit a pull request

## License

This project is maintained by the Umbraco HQ team for internal load testing purposes.
