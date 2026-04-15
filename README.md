# Umbraco Load Testing Infrastructure

Automated infrastructure for load testing multiple Umbraco CMS versions on Azure using Terraform, Locust, and Azure Load Testing.

## Overview

This project provisions isolated Azure environments for each Umbraco version, seeds them with test data using [PerformanceTestDataSeeder](https://github.com/umbraco/Umbraco.Community.PerformanceTestDataSeeder) (v17+) or [DummyDataSeeder](https://github.com/nhudinh0309/performance-test-data-v13) (v13-16), and runs Locust load tests via Azure Load Testing service.

Locust tests execute on Azure Load Testing's managed infrastructure (dedicated Standard_D4d_v4 VMs), not on the pipeline agent. This ensures consistent, reliable performance measurements.

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
├── azure-pipeline.yml           # Main CI/CD pipeline
├── README.md
│
├── templates/
│   └── load-test-job.yml        # Reusable per-version load test template
│
├── scripts/
│   ├── bootstrap-history-infra.ps1     # Idempotently provisions the long-lived RG, ALT, storage
│   └── publish-load-test-results.ps1   # Exports per-test metrics + raw artifacts to history storage
│
├── loadtests/
│   ├── locustfile.py            # Test plan — currently a homepage smoke-test scaffold
│   ├── locust.conf              # Local development config
│   └── requirements.txt         # Extra Python packages installed on ALT engines
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
| `appServicePlanSku` | App Service Plan tier | P1v3 | P1v3-P3v3 (Cloud), P0v4-P5mv4 (Dedicated) |
| `sqlSku` | SQL Database tier | S0 | S0, S1, S2 |
| `sqlMaxSizeGb` | SQL Database max size | 5 | 2, 5, 10, 20 |
| `azureRegion` | Azure region | West Europe | West Europe, North Europe, East US, West US 2 |
| `prefix` | Resource name prefix | umbraco-azure-load-test-pipeline | - |
| `userAmount` | Virtual users for load test | 100 | 50, 100, 150, 200, 250, 300 |
| `spawnRate` | Users spawned per second (ramp-up speed) | 10 | 5, 10, 20, 50 |
| `testDuration` | Steady-state duration in seconds | 300 | 60, 120, 180, 300, 600 |
| `coldStart` | Skip warmup (test cache warm-up) | false | true, false |
| `seederPreset` | Data seeding volume | Medium | Small, Medium, Large, Massive |

### Version Configuration

Versions are configured via Azure DevOps variable groups:

| Variable | Description | Example |
|----------|-------------|---------|
| `firstDotNetVersion` | .NET version for first test | v8.0 |
| `firstUmbracoVersion` | Umbraco version for first test | 14.3.0 |
| `secondDotNetVersion` | .NET version for second test | v9.0 |
| `secondUmbracoVersion` | Umbraco version for second test | 15.1.0 |
| (up to fourth) | ... | ... |

## Load Test Scenarios

`loadtests/locustfile.py` currently contains only a **homepage smoke-test User** that hits `/`. It exists to validate the end-to-end pipeline (provisioning -> deploy -> seed -> ALT engine -> results upload), not to exercise real workloads.

Real scenarios will be added later. To add one:

1. Define an `HttpUser` subclass either in `locustfile.py` or in a sibling module
2. If you create new modules, add them to the `configurationFiles:` list in `templates/load-test-job.yml` so ALT uploads them to the test engines

### Load Pattern

Azure Load Testing controls the load pattern:
- **Ramp-up**: Users are spawned at a configurable rate (default: 10/second)
- **Steady-state**: All virtual users active for the test duration
- **Ramp-down**: Handled by ALT when the test duration expires

### Cold Start Testing

Set `coldStart: true` to skip the warmup poll. The load test then hits a freshly started App Service with cold caches, measuring the full delivery pipeline including initial cache population.

## Results

The pipeline writes results to three places:

- **Azure Load Testing portal**: dashboard with client-side metrics (response time, throughput, errors) and server-side metrics (CPU, memory, network, disk). The ALT resource lives in a **long-lived, shared resource group** (see "Infrastructure" below) so run history accumulates across pipeline runs. Each run is named `Umbraco {version} - {branch}@{commit} - run {buildId}` for easy identification.
- **Pipeline artifacts**: per-test ZIP under `loadtest-results-{N}` on the build, useful for forensic deep-dives. Expires with the pipeline's build retention policy.
- **History storage account** (long-lived): for each test, a per-scenario NDJSON summary at `runs/{yyyy/MM/dd}/{buildId}/test-{N}/summary.ndjson` plus the raw artifact dump under `raw/`. Each row carries the full run metadata (commit, version, SKUs, seeder preset, user count), so cross-run queries don't need joins.

NDJSON is ingestible directly by Azure Data Explorer, pandas, Postgres `COPY`, etc. — pick whatever query layer fits, the data shape stays the same.

### Infrastructure: ephemeral vs long-lived

The pipeline manages two separate resource groups:

| Resource group | Lifetime | Contents |
|---|---|---|
| `${prefix}-rg` (ephemeral) | Created and destroyed per pipeline run | App Service plan, App Services, SQL servers + databases for each Umbraco version |
| `umbraco-loadtest-history-rg` (long-lived) | Created once, never deleted by the pipeline | Shared Azure Load Testing resource, storage account for results history |

The long-lived RG is bootstrapped idempotently at the start of every pipeline run by `scripts/bootstrap-history-infra.ps1` — first run creates it, subsequent runs no-op. Override the names via the `historyResourceGroup`, `historyLoadTestName`, `historyStorageAccount`, `historyContainer` pipeline variables (or pin them in a variable group) if multiple teams share the subscription. **The storage account name must be globally unique and 3-24 lowercase alphanumeric chars.**

## Pipeline Workflow

```
1. Check Resource Group     -> Does it already exist?
2. Format Versions          -> Convert variables to Terraform JSON
3. Terraform Plan           -> Preview infrastructure changes
4. Terraform Apply          -> Provision Azure resources
5. Deploy Umbraco           -> Install CMS on each App Service
6. Seed Data                -> Data seeder populates content
7. Run Load Tests           -> Sequential Locust tests per version (on ALT infra)
8. Manual Validation        -> 1 hour window to keep resources
9. Cleanup                  -> Delete resource group if rejected/expired
```

## Data Seeder Presets

| Preset | Documents | Media | Members | Approx. Time |
|--------|-----------|-------|---------|--------------|
| Small | ~100 | ~50 | ~20 | 2-5 min |
| Medium | ~500 | ~200 | ~100 | 5-15 min |
| Large | ~2000 | ~500 | ~500 | 15-30 min |
| Massive | ~10000 | ~2000 | ~2000 | 30-60 min |

## Usage

### Running via Azure Pipelines

1. Configure your Azure DevOps variable group with the Umbraco versions to test
2. Run the pipeline manually from Azure DevOps
3. Select desired parameters (SKU, user count, cold start, etc.)
4. Wait for infrastructure provisioning and load tests to complete
5. Review results in Azure Load Testing portal and pipeline artifacts
6. Approve or reject resource cleanup within 1 hour

### Running Terraform Locally

```bash
cd Terraform
terraform init
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
terraform plan
terraform apply
```

### Running Locust Locally

```bash
cd loadtests
pip install locust
locust -f locustfile.py --host https://<app-service-url>
# Open http://localhost:8089 to configure and start the test
```

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
