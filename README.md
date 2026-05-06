# Umbraco Load Testing Infrastructure

Automated infrastructure for load testing multiple Umbraco CMS versions on Azure using Terraform, Locust, and Azure Load Testing.

## Overview

This project provisions isolated Azure environments for arbitrary combinations of **(Umbraco version × infrastructure tier × scenario)**, seeds them with test data using [Umbraco.Cms.TestDataSeeder](https://www.nuget.org/packages/Umbraco.Cms.TestDataSeeder/), and runs Locust load tests via Azure Load Testing service.

**Supported Umbraco versions: v17 and newer.** Older majors (v13–v16) are rejected at validation time — the seeder package doesn't yet have a release train for them.

Locust tests execute on Azure Load Testing's managed infrastructure (dedicated Standard_D4d_v4 VMs), not on the pipeline agent. This ensures consistent, reliable performance measurements.

A pipeline run is parameterised by a list of **test cases**. Each case picks:

- **Umbraco/.NET version pair** (e.g. `17.0.0` on `v10.0`)
- **Infrastructure tier** — `Starter` / `Standard` / `Pro`, defined in [`loadtests/tiers.json`](loadtests/tiers.json) (App Service Plan SKU + SQL SKU + max DB size)
- **Scenario** — a folder under `loadtests/scenarios/` containing the Umbraco `appsettings.json` overlay for that scenario plus optional `scenario.yaml` load-profile overrides

Cases on the same tier in one run share an App Service Plan; cases on different tiers each get their own. Tests within a run run sequentially (one App Service hot at a time) so each measurement gets the full plan capacity.

## Prerequisites

- Azure subscription with appropriate permissions
- Azure DevOps organization with:
  - Service connection to Azure (`terraform-umbraco-load-testing-az-connection`)
  - Override of `historyStorageAccount` in pipeline variables (the default `loadtestchangeme` is an obvious placeholder that fails name-availability check; replace with your own globally-unique 3–24 lowercase alphanumeric value)
- Terraform >= 1.3.9
- PowerShell Core (pwsh) 7+

## Project Structure

```
├── azure-pipeline.yml           # Main load test pipeline (manual queue)
├── README.md
│
├── templates/
│   └── load-test-job.yml        # Per-case load test template (testCaseId lookup pattern)
│
├── scripts/
│   ├── ensure-history-infra.ps1        # Idempotently provisions long-lived RG, Azure Load Testing, storage
│   ├── prepare-test-cases.ps1          # Validator: validates testCases, flattens scenario appsettings,
│   │                                   #            resolves load profile, emits testCasesJson + resolvedTestCases
│   ├── verify-deployments.ps1          # Smoke-check each deployed site (skipLoadTests=true path)
│   ├── stop-all-app-services.ps1       # End-of-run sweep: stop all App Services in the case set
│   └── publish-load-test-results.ps1   # Exports per-test NDJSON + raw artifacts to history storage
│
├── loadtests/
│   ├── locustfile.py            # Inventory-driven workload (CMS browsing + contact-form write path)
│   ├── locust.conf              # Local development config
│   ├── tiers.json               # Tier catalog (Starter / Standard / Pro → SKUs)
│   └── scenarios/
│       └── Default/
│           ├── AdditionalSetup/
│           │   └── appsettings.json  # {} — identity overlay
│           └── scenario.yaml         # description; no profile overrides
│
└── Terraform/
    ├── main.tf                  # Root module
    ├── variables.tf             # Input variables (testCases-shaped test_cases)
    ├── output.tf                # test_case_outputs map keyed by testCaseId
    ├── terraform.tfvars.example # Example configuration
    │
    └── modules/umbraco/
        ├── main.tf              # Reads tiers.json; for_each App Service Plan over tiers in use
        ├── variables.tf
        ├── output.tf
        │
        ├── scripts/
        │   └── install-umbraco-cms-on-appservice.ps1
        │
        └── versions/            # Per-case resources
            ├── main.tf          # SQL Server, Database, App Service (merges overlay into app_settings)
            ├── variables.tf
            └── output.tf
```

## Configuration

### Pipeline Parameters

The queue UI is a small set of dropdowns. The headline parameter is **profile**, which encodes "what kind of test do you want to run" — picking a profile sets the tier list, seeder preset, VU count, duration, and engine count in one shot.

**What to test:**

| Parameter | Description | Default | Options |
|-----------|-------------|---------|---------|
| `profile` | Run profile — encodes tier list, seeder preset, VUs, duration, engines (see table below) | smoke | smoke, compare-tiers, full-comparison, stress |
| `umbracoVersion` | Umbraco CMS version | 17.0.0 | extend the `values` list as new versions ship |
| `dotnetVersion` | .NET runtime version | v10.0 | extend the `values` list as new .NET versions ship |
| `scenario` | Scenario folder name (must match a folder under `loadtests/scenarios/`) | Default | extend the `values` list when adding scenarios |

**Profiles:**

| Profile | Tiers | Seeder preset | VUs | Spawn rate | Duration | Engines |
|---|---|---|---|---|---|---|
| `smoke` | Starter | Small | 50 | 10/s | 60s | 1 |
| `compare-tiers` | Starter, Standard | Medium | 100 | 10/s | 300s | 1 |
| `full-comparison` | Starter, Standard, Pro | Medium | 100 | 10/s | 300s | 1 |
| `stress` | Pro | Large | 300 | 50/s | 600s | 2 |

Adding or tuning a profile is a two-place edit in `azure-pipeline.yml`: extend the inline `switch` in the "Resolve profile + validate scenario" step (sets the tuple), **and** update the three `${{ if in(parameters.profile, …) }}` blocks in the `runLoadTests` job that decide which tiers the new profile expands into. The compile-time conditionals can't read the runtime resolver output, so both edits are required — miss the second and the pipeline silently runs zero load tests.

**For multi-version comparisons in a single queue** (e.g. 17.0.0 vs 17.0.1 on the same tier): queue the pipeline twice — once per version. The ALT Compare runs view aggregates across pipeline runs anyway (testId is per-scenario, not per-pipeline-run), so two queues end up in the same comparison view.

**Run configuration (orthogonal knobs):**

| Parameter | Description | Default | Options |
|-----------|-------------|---------|---------|
| `azureRegion` | Azure region | West Europe | West Europe, North Europe, East US, West US 2 |
| `prefix` | Resource name prefix (max 16 chars) | umbraco-loadtest | — |
| `coldStart` | Skip warmup (test cache warm-up behaviour) | false | true, false |
| `skipLoadTests` | Skip load tests (infra-only run) | false | true, false |
| `validationTimeoutMinutes` | How long resources stay alive after tests | 60 | 15, 30, 60, 120, 240 |

The validator (`scripts/prepare-test-cases.ps1`) catches typos, missing scenario folders, and duplicate `(umbraco, tier, scenario)` triples *before* any Azure resource is provisioned. It also enforces sensible ranges on the load profile values the profile resolver hands it (`userAmount` 1–1000, `spawnRate` 1–100, `testDuration` 30–7200 seconds).

## Tiers

`loadtests/tiers.json` is the **single source of truth** for tier names + SKUs. Both Terraform (provisioning) and the PowerShell validator read this same file:

```json
{
  "tiers": {
    "Starter":  { "app_sku": "P0v4", "sql_sku": "S0", "sql_max_size_gb": 5 },
    "Standard": { "app_sku": "P1v3", "sql_sku": "S1", "sql_max_size_gb": 10 },
    "Pro":      { "app_sku": "P3v3", "sql_sku": "S2", "sql_max_size_gb": 20 }
  }
}
```

Add a tier by adding a key here. Both the validator and Terraform will pick it up automatically.

A pipeline run only provisions plans for tiers actually referenced by its `testCases` — an all-Standard run creates one plan; a mixed-tier run creates one per distinct tier in use.

## Scenarios

A **scenario** is an Umbraco-side configuration variant. The layout mirrors how Umbraco's own [acceptance test repo](https://github.com/umbraco/Umbraco-CMS) organises tests — a folder per scenario with an `AdditionalSetup/appsettings.json` carrying the configuration overlay:

```
loadtests/scenarios/
  Default/
    AdditionalSetup/
      appsettings.json     # {} — empty overlay
    scenario.yaml          # description; no profile overrides
  RedisCache/              # add when needed
    AdditionalSetup/
      appsettings.json     # Redis-specific Umbraco keys
    scenario.yaml          # optional load profile overrides
```

### Naming convention

Name scenarios after **what they configure**, not what they test. Examples that fit the convention: `Default`, `RedisCache`, `LuceneDisabled`, `BackofficeOnly`. Examples that don't: `BulkPublishTest`, `PerfRun3` — those are tests, not configs.

This matches Umbraco's pattern (`ContentSettingConfig`, `DeliveryApi`, `SMTP` …) and means future per-scenario test plans will live naturally inside the same folder.

### Naming constraints

Scenario names participate in Azure resource names (App Service is capped at 60 chars), so the validator enforces:

- **≤ 15 characters** (e.g. `RedisCache` ✓, `BackofficeOnly` ✓, `ContentDeliveryApi` ✗)
- **alphanumeric + hyphens only** (no underscores, dots, spaces). Folder names are matched case-strictly on every agent (the validator enumerates the actual folders and rejects mismatches with a "did you mean 'X'?" hint).

The `resource_name_prefix` Terraform variable is similarly capped at **16 chars** (validated). Default is `umbraco-loadtest`. The 60-char App Service budget breaks down as:

```
${prefix}-appservice-${umbraco}-${tier}-${scenario}
   ≤16        12           ≤7      ≤8       ≤15        + connectors = 60 max
```

Long Umbraco prerelease tags (e.g. `17.0.0-rc.1.beta`) eat into the budget. Prefer release versions (`X.Y.Z`) when possible, and shorten the scenario name if running prereleases on a long-named tier.

### `appsettings.json` overlay

The contents of a scenario's `AdditionalSetup/appsettings.json` are **flattened** by the validator to App Service envvar form (`Section:Sub:Key` → `Section__Sub__Key`) and **merged into the base `app_settings` block** of the deployed App Service. Overlay keys win over base keys.

Example — `loadtests/scenarios/RedisCache/AdditionalSetup/appsettings.json`:

```json
{
  "Umbraco": {
    "CMS": {
      "DistributedLockingMechanism": "RedisDistributedLockingMechanism"
    }
  },
  "ConnectionStrings": {
    "Redis": {
      "ConnectionString": "redis://..."
    }
  }
}
```

Becomes (in the App Service `app_settings`):

```
Umbraco__CMS__DistributedLockingMechanism = RedisDistributedLockingMechanism
ConnectionStrings__Redis__ConnectionString = redis://...
```

⚠️ **Overlay precedence sharp edge.** Because overlay keys win over base keys, a sufficiently aggressive scenario can clobber base settings — including `Umbraco__CMS__Unattended__*` (which would break unattended install) or `Umbraco.Cms.TestDataSeeder__Options__Preset` (which would override the run-level seeder preset). This is intentional flexibility, but be deliberate about what your overlay touches.

### Code overlays (`*.cs`, `*.cshtml`, `App_Plugins/`, …)

Some Umbraco features can't be flipped via `appsettings.json` alone — they need source-code changes (e.g. `.AddDeliveryApi()` in the builder chain, custom composers, backoffice extensions). Mirroring how Umbraco's acceptance tests handle this, **any file in `AdditionalSetup/` other than `appsettings.json` is treated as a code overlay**: copied into the dotnet project tree before `dotnet build`, preserving relative paths.

Example — enabling Delivery API requires a custom `Program.cs`:

```
loadtests/scenarios/DeliveryApi/
  AdditionalSetup/
    appsettings.json     # { "Umbraco": { "CMS": { "DeliveryApi": { "Enabled": true } } } }
    Program.cs           # CreateUmbracoBuilder().AddBackOffice().AddWebsite().AddDeliveryApi()…
```

When the install script deploys the `DeliveryApi` scenario:

1. `dotnet new umbraco -n …` creates the project (with a default `Program.cs`).
2. The seeder package is added (`dotnet add package …`).
3. **Code overlay is applied**: `Program.cs` from the scenario's `AdditionalSetup/` overwrites the generated one. Any other files (e.g. `Composers/MyComposer.cs`, `wwwroot/App_Plugins/myplugin/...`) are copied to the same relative path under the project root.
4. `dotnet build` picks up the overlay automatically.

Convention notes:
- Mirror the dotnet project structure inside `AdditionalSetup/`. A file at `AdditionalSetup/Composers/MyComposer.cs` lands at `<project>/Composers/MyComposer.cs`.
- For Umbraco 14+ backoffice extensions, drop your built JS/TS into `AdditionalSetup/wwwroot/App_Plugins/{Name}/`.
- Scenarios with broken C# will fail `dotnet build` — the install script propagates the failure to the pipeline run.
- An empty `AdditionalSetup/` (or one containing only `appsettings.json`, like `Default`) just skips the overlay step.

### `scenario.yaml` schema

Optional metadata + load profile overrides:

```yaml
description: "Free-text description shown in run summaries"   # optional
loadProfile:                                                  # optional whole block
  users:     200    # overrides pipeline.userAmount    when present
  spawnRate:  20    # overrides pipeline.spawnRate     when present
  duration:  600    # overrides pipeline.testDuration  when present
```

All fields optional. A missing `scenario.yaml` (or an empty `loadProfile` block) means the case uses the queue-time pipeline-level defaults. The override resolution happens once in the validator — every downstream consumer (Terraform, Azure Load Testing, NDJSON publisher) sees the resolved values, not the override logic.

### Adding a new scenario

1. Create `loadtests/scenarios/{Name}/AdditionalSetup/appsettings.json` with your config overlay.
2. Optionally add `loadtests/scenarios/{Name}/scenario.yaml` with description + load profile overrides.
3. Reference it in a `testCases` entry: `scenario: '{Name}'`.

That's it. No HCL or pipeline edits needed.

### Load Pattern

Azure Load Testing controls the load pattern:
- **Ramp-up**: Users are spawned at the resolved spawn rate
- **Steady-state**: All virtual users active for the resolved duration
- **Ramp-down**: Handled by Azure Load Testing when the test duration expires

### Cold Start Testing

Set `coldStart: true` to skip the warmup poll. The load test then hits a freshly started App Service with cold caches, measuring the full delivery pipeline including initial cache population.

## Results

The pipeline writes results to three places:

- **Azure Load Testing portal**: dashboard with client-side metrics (response time, throughput, errors) and server-side metrics (CPU, memory, network, disk). The Azure Load Testing resource lives in a **long-lived, shared resource group** (see "Infrastructure" below) so run history accumulates across pipeline runs. There's **one load test per scenario** (testId `umbraco-lt-{scenario}`), with every (version, tier) run nested under it — so the portal's "Compare runs" view lets you pick multiple runs and overlay their metrics natively. Each run is named `{umbracoVersion} {tier} #{buildId}`.
- **Pipeline artifacts**: per-case ZIP under `loadtest-results-{sanitised-testCaseId}` on the build, useful for forensic deep-dives. Expires with the pipeline's build retention policy.
- **History storage account** (long-lived): per-case NDJSON summary at `{scenario}/{major}/{umbracoVersion}/{tier}/{yyyy-MM-dd}_{buildId}/summary.ndjson` plus the raw artifact dump under `raw/`. Scenario is top-level because it defines what's *comparable* — different scenarios hit different endpoints / seed different data, so their numbers can't be compared directly. Within a scenario, prefix-listing maps to the natural pivots: `Default/17/` trends a major, `Default/17/17.0.0/` is all tiers in one build, `Default/17/*/Starter/` sweeps versions on one tier. Each row carries the full run metadata (commit, version, tier, scenario, SKUs, seeder preset, user count), so cross-run queries don't need joins.

NDJSON is ingestible directly by Azure Data Explorer, pandas, Postgres `COPY`, etc. — pick whatever query layer fits, the data shape stays the same.

### Comparing two runs

For the everyday "did this tier/version actually move the needle?" question, download the raw `engine1_results.csv` from each run's pipeline artifact (or directly from the ALT portal) and feed both to `scripts/compare-runs.ps1`:

```powershell
./scripts/compare-runs.ps1 `
    -BaselinePath  ./starter-17.0.0/engine1_results.csv `
    -CandidatePath ./standard-17.0.0/engine1_results.csv `
    -BaselineLabel "Starter 17.0.0" `
    -CandidateLabel "Standard 17.0.0" `
    -OutputPath compare.md
```

The script emits a markdown report with:
- **Aggregate** count/avg/p50/p95/p99/max for each run + percentage delta
- **Per-sampler** breakdown (Detail, Page, Category, etc.) ordered by traffic share, with deltas bolded when they cross the significance threshold (default 10%)
- A "How to read this" footer explaining what the deltas actually mean (p95/p99 are the tier-discriminating metrics; max is single-sample noise; cached paths won't move regardless of tier)

Use the same script for any pair of runs — version-vs-version on a fixed tier, scenario-vs-scenario, before-vs-after a code change.

### Infrastructure: ephemeral vs long-lived

The pipeline manages two separate resource groups:

| Resource group | Lifetime | Contents |
|---|---|---|
| `${prefix}-rg` (ephemeral) | Created and destroyed per pipeline run | App Service plans (one per used tier), App Services + SQL servers + databases (one per case) |
| `umbraco-loadtest-history-rg` (long-lived) | Created once, never deleted by the pipeline | Shared Azure Load Testing resource, storage account for results history |

The long-lived RG is provisioned idempotently at the start of every pipeline run by `scripts/ensure-history-infra.ps1` — first run creates it, subsequent runs no-op. Override the names via the `historyResourceGroup`, `historyLoadTestName`, `historyStorageAccount`, `historyContainer` pipeline variables (or pin them in a variable group) if multiple teams share the subscription. **The storage account name must be globally unique and 3-24 lowercase alphanumeric chars.**

## Pipeline Workflow

```
0. validateTestCases            -> Validate testCases, read scenario folders, resolve load profile
1. ensureHistoryInfra           -> Idempotent: shared Azure Load Testing + storage
2. Check Resource Group         -> Does it already exist?
3. Terraform Setup              -> Init + Validate + Plan
4. Terraform Apply              -> Provision App Service Plans (one per tier), per-case App Services + SQL DBs
5. Verify Deployments           -> Smoke-check each site (only when skipLoadTests=true)
6. Run Load Tests               -> Sequential per-case Locust tests (on Azure Load Testing infra)
7. Test Summary                 -> Print run-level + per-case config
8. Manual Validation            -> Configurable window to keep resources (default 60 min)
9. Cleanup                      -> Delete resource group if rejected/cancelled/expired
```

## Data Seeder Presets

| Preset | Documents | Media | Members | Approx. Time |
|--------|-----------|-------|---------|--------------|
| Small | ~100 | ~50 | ~20 | 2-5 min |
| Medium | ~500 | ~200 | ~100 | 5-15 min |
| Large | ~2000 | ~500 | ~500 | 15-30 min |
| Massive | ~10000 | ~2000 | ~2000 | 30-60 min |

The seeder preset is **run-level** — applied uniformly to every case. (A scenario *can* override it via the `appsettings.json` overlay key `Umbraco.Cms.TestDataSeeder__Options__Preset` if you really need it per-case, but that's the overlay-precedence sharp edge — be deliberate.)

## Usage

### Running via Azure Pipelines

1. Run the pipeline manually from Azure DevOps.
2. Edit `testCases` in the queue-time YAML editor (defaults to v17.0.0 × all 3 tiers on the `Default` scenario).
3. Adjust other parameters (region, default users, seeder preset, cold start, etc.) as needed.
4. Wait for validation → ensure-history-infra → provisioning → load tests to complete.
5. Review results in Azure Load Testing portal, pipeline artifacts, and history storage NDJSON.
6. Approve or reject resource cleanup within the validation window (default 60 min).

### Running Terraform Locally

```bash
cd Terraform
terraform init
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — note the testCaseId-keyed map shape
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

**Preflight fails with "tier 'X' is not in tiers.json"**
- Check `loadtests/tiers.json` — the tier catalog. Either fix the typo in your `testCases` entry or add the tier to the catalog.

**Preflight fails with "scenario folder not found"**
- The scenario folder must exist at `loadtests/scenarios/{Name}/AdditionalSetup/appsettings.json`. Folder lookup is case-strict on every agent — the validator will suggest the closest match if the casing differs.

**Preflight fails with "duplicate testCaseId"**
- You have two cases with the same `(umbraco, tier, scenario)` triple. Either remove the duplicate, or change one of the dimensions (e.g. different scenario folder).

**Seeder not completing**
- Large presets can take up to 60 minutes
- Check seeder status: `https://<hostname>/umbraco/api/seederstatus/status`

**Template version mismatch**
- Ensure Umbraco template version matches CMS version
- Pre-release versions require NuGet sources (automatically configured)

## Local checks before queueing

```bash
cd Terraform && terraform fmt -check -recursive && terraform init -backend=false && terraform validate
Invoke-ScriptAnalyzer -Path . -Recurse -Severity Warning,Error -ExcludeRule PSAvoidUsingWriteHost
```

## Azure resource tagging

Every provisioned resource carries:

| Tag | Where | Value |
|---|---|---|
| `project` | All | `umbraco-loadtest` |
| `managed_by` | Ephemeral resources | `terraform` |
| `managed_by` | Long-lived history infra | `ensure-script` |
| `build_id` | Ephemeral resources | `$(Build.BuildId)` from the pipeline (or `local` for hand runs) |
| `tier` | App Service Plan | The tier name (`Starter` / `Standard` / `Pro`) |
| `test_case_id` | App Service, SQL Server, SQL DB | The full testCaseId |
| `umbraco_version` | App Service, SQL Server, SQL DB | The Umbraco CMS version |
| `scenario` | App Service, SQL Server, SQL DB | The scenario folder name |

Cost reports in Azure Portal can group/filter by any of these — `managed_by` separates the per-run ephemeral spend from the long-lived history infra.

Pre-existing untagged history infra (created before this change) won't be retroactively tagged. Either re-tag manually (`az group update -n umbraco-loadtest-history-rg --set tags.project=umbraco-loadtest tags.managed_by=ensure-script`) or recreate the RG.

