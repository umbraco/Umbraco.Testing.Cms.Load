# Umbraco Load Testing Infrastructure

A starting point for load testing Umbraco CMS on Azure using Terraform, Locust, and Azure Load Testing. The focus is establishing CMS performance baselines, but the infrastructure, pipeline, and test framework are designed to be reusable — other teams (Cloud, DXP, Workflow, Commerce, …) can fork the repo, add their own packages and configuration, and build team-specific scenarios on top of the same foundation.

## Goals

- **Establish CMS performance baselines** — repeatable, comparable metrics for Umbraco under standard conditions across versions.
- **Enable version comparison** — run the same scenario against multiple Umbraco versions to detect regressions or improvements.
- **Build infrastructure capacity benchmarks** — what each App Service + SQL SKU combination can handle, as reference data for sizing decisions. (The shipped tiers fix the App Service at `P1v3` to mirror Umbraco Cloud's reality and vary SQL eDTU; the `sqlSkuOverride` parameter and `tiers.json` are the levers for sweeping other combinations.)
- **Provide a reusable foundation** — a working pipeline + harness that other teams can extend without rebuilding infra.

Thresholds (fail-the-pipeline gates) are intentionally **deferred** until baselines exist — once we know what "normal" looks like per scenario per tier, Locust thresholds can be wired in to fail on regression.

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

- Azure subscription with appropriate permissions. The pipeline service principal needs:
  - Standard create/manage rights on the ephemeral and history resource groups (Contributor is enough for resources).
  - **`Microsoft.Storage/storageAccounts/listKeys/action`** on the history storage account — Storage Account Contributor (or any role that includes `listKeys/action`) is enough. Downstream scripts (`publish-load-test-results.ps1`, `_history-helpers.ps1`) fetch the account key at runtime and authenticate with `--account-key`. RBAC + `--auth-mode login` would be a stricter alternative but requires `Microsoft.Authorization/roleAssignments/write` for the SP, which is a heavier permissions ask.
- Azure DevOps organization with:
  - Service connection to Azure (`terraform-umbraco-load-testing-az-connection`)
  - Variable group `umbraco-loadtest-history` with at minimum: `historyResourceGroup`, `historyLocation`, `historyLoadTestName`, `historyStorageAccount` (override the placeholder `loadtestchangeme` with a globally-unique 3-24 lowercase alphanumeric value), `historyContainer`.
- Terraform >= 1.3.9
- PowerShell Core (pwsh) 7.3+ — earlier versions silently swallow native command failures (`dotnet build` errors etc.) because `$ErrorActionPreference = "Stop"` doesn't apply to native exit codes; 7.3 introduced `$PSNativeCommandUseErrorActionPreference` which the install script sets.

## First-time setup

A new team forking this project should:

1. **Pick a globally-unique storage account name** (3-24 lowercase alphanumeric chars). This will host the long-lived run history. Override `historyStorageAccount` in the variable group with this value — the placeholder `loadtestchangeme` is rejected by `ensure-history-infra.ps1`.
2. **Create the AzDO variable group** `umbraco-loadtest-history` with the five history variables above.
3. **Configure the service principal** with the permissions listed in Prerequisites — Contributor on the subscription (or scoped narrower) is sufficient.
4. **Queue the pipeline once with `skipLoadTests=true`.** The first run creates the long-lived history infra (RG, ALT resource, storage account, container) and verifies the per-case provisioning path without committing to a full load test. ~10-15 minutes.
5. **(Local-dev users)** `az login` and verify you can list keys for the history storage account — `show-trends.ps1` / `check-regression.ps1` / `compare-runs.ps1` (history mode) run locally need the same `listKeys/action` the pipeline SP uses:
   ```bash
   az storage account keys list -n <your-history-storage-account> -g umbraco-loadtest-history-rg --query "[0].keyName" -o tsv
   ```
   If that command works, the analysis tools will work. If it fails with "AuthorizationFailed", grant yourself Storage Account Contributor (or higher) on the SA scope.
6. **Queue 3-5 baseline runs** with the same configuration to populate history (see "Establishing a baseline" below). Until cells have ≥ 3 prior runs, the pipeline's regression-check stage reports "insufficient baseline" and exits 0 — it's safe to enable from day one.

### Cost awareness

Every queued run provisions an ephemeral RG with an App Service Plan (P1v3) per tier and a SQL DB per case. The plan + DB cost continues to accrue from the moment the RG is created until cleanup. With `validationTimeoutMinutes=240` (the maximum) and a multi-tier run, a forgotten run (no approve, no reject — just walk away) can rack up a half-day of premium SKU billing. Default is 60 min; bump to 120/240 only when you actually need that long to inspect resources, and prefer rejecting cleanup explicitly when done. There's no automated budget alert on the ephemeral RG today — adding an `azurerm_consumption_budget_resource_group` to `Terraform/main.tf` with an action group is a reasonable next step for any team treating this as production.

## Project Structure

```
├── azure-pipeline.yml           # Main load test pipeline (manual queue)
├── pr-validation.yml            # PR-time static checks (terraform/PS/Python/YAML lint, no Azure)
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
│   ├── publish-load-test-results.ps1   # Exports per-test NDJSON + raw artifacts to history storage
│   ├── compare-runs.ps1                # Markdown delta report between two engine_results.csv files (one-vs-one)
│   ├── show-trends.ps1                 # (version × tier) p95/p99/error% matrix from history NDJSON (many-vs-many)
│   ├── check-regression.ps1            # Compare latest run vs baseline-median; non-zero exit on regression (gate)
│   └── _history-helpers.ps1            # Shared helpers for the history-NDJSON consumers (dot-sourced)
│
├── loadtests/
│   ├── locustfile.py            # Inventory-driven workload (CMS browsing + contact-form write + Delivery API splice)
│   ├── locust.conf              # Local development config
│   ├── tiers.json               # Tier catalog (Starter / Standard / Pro → SKUs)
│   └── scenarios/
│       ├── Default/
│       │   ├── AdditionalSetup/
│       │   │   └── appsettings.json  # {} — identity overlay
│       │   └── scenario.yaml         # description; no profile overrides
│       └── DeliveryApi/
│           ├── AdditionalSetup/
│           │   └── appsettings.json  # enables Umbraco:CMS:DeliveryApi
│           └── scenario.yaml
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

The queue UI splits into three concerns: **what to test**, **which tiers to test it on**, and **how hard to test**. Each lives on its own knob so you can mix freely (e.g. "stress profile against Standard only" or "smoke profile against all three tiers").

**What to test:**

| Parameter | Description | Default | Options |
|-----------|-------------|---------|---------|
| `umbracoVersion` | Umbraco CMS version. Free-text — accepts prereleases (`17.0.0-rc.1`, `17.1.0-beta.2`). The validator enforces v17+ and a recognisable `X.Y.Z[-suffix]` shape; the major segment maps to the .NET runtime automatically. | 17.0.0 | free text |
| `scenario` | Scenario folder name (must match a folder under `loadtests/scenarios/`) | Default | extend the `values` list when adding scenarios |

**Which tiers:**

| Parameter | Description | Default |
|-----------|-------------|---------|
| `runStarter` | Run the Starter (S1) tier | true |
| `runStandard` | Run the Standard (S2) tier | false |
| `runPro` | Run the Pro (S3) tier | false |

At least one tier must be selected — the validator fails the run if all three are unchecked.

**Load profile (intensity):**

| Profile | Seeder preset | VUs | Spawn rate | Duration | Engines |
|---|---|---|---|---|---|
| `smoke` | Small | 50 | 10/s | 60s | 1 |
| `standard` | Medium | 100 | 10/s | 300s | 1 |
| `stress` | Large | 300 | 50/s | 600s | 2 |

The profile only encodes load intensity — the same profile can drive any combination of tiers. Tuning a profile is a single-place edit to the inline `switch` in `azure-pipeline.yml`'s "Resolve profile + validate scenario" step.

**.NET runtime is derived, not selected.** The prep step maps the Umbraco major version → required .NET runtime (currently 17+→.NET 10; older majors are rejected by the validator and unreachable here). Extend the mapping when a future Umbraco version bumps the target framework.

**For multi-version comparisons in a single queue** (e.g. 17.0.0 vs 17.0.1 on the same tier): queue the pipeline twice — once per version. The ALT Compare runs view aggregates across pipeline runs anyway (testId is per-scenario, not per-pipeline-run), so two queues end up in the same comparison view.

**Run configuration (orthogonal knobs):**

| Parameter | Description | Default | Options |
|-----------|-------------|---------|---------|
| `azureRegion` | Azure region | West Europe | West Europe, North Europe, East US, West US 2 |
| `resourcePrefix` | Resource name prefix (max 16 chars) | umbraco-loadtest | — |
| `skipWarmup` | Skip warmup (test cold-start / cache warm-up behaviour) | false | true, false |
| `skipLoadTests` | Skip load tests (infra-only run) | false | true, false |
| `validationTimeoutMinutes` | How long resources stay alive after tests | 60 | 15, 30, 60, 120, 240 |
| `sqlSkuOverride` | Force every case onto a specific SQL SKU (decouples DB sizing from tier) | Auto | Auto, S0, S1, S2, S3 |

**SQL SKU override.** When set to a value other than `Auto`, every test case in the run uses the same SQL DB SKU regardless of the tier's nominal pairing — useful for cross-checking whether SQL is actually the bottleneck. Default pairings are Starter→S1, Standard→S2, Pro→S3 (see `tiers.json`); since all three tiers share the same App Service SKU today, the override is mainly for "is the app saturating before SQL does?" experiments. The `sql_max_size_gb` cap stays at the tier default (5/10/20 GB) — manually edit `tiers.json` if a larger cap is needed alongside an SKU bump.

The validator (`scripts/prepare-test-cases.ps1`) catches typos, missing scenario folders, and duplicate `(umbraco, tier, scenario)` triples *before* any Azure resource is provisioned. It also enforces sensible ranges on the load profile values the profile resolver hands it (`userAmount` 1–1000, `spawnRate` 1–100, `testDuration` 30–7200 seconds).

## Tiers

`loadtests/tiers.json` is the **single source of truth** for tier names + SKUs. Both Terraform (provisioning) and the PowerShell validator read this same file:

```json
{
  "tiers": {
    "Starter":  { "app_sku": "P1v3", "sql_sku": "S1", "sql_max_size_gb": 5  },
    "Standard": { "app_sku": "P1v3", "sql_sku": "S2", "sql_max_size_gb": 10 },
    "Pro":      { "app_sku": "P1v3", "sql_sku": "S3", "sql_max_size_gb": 20 }
  }
}
```

Add a tier by adding a key here. Both the validator and Terraform will pick it up automatically — but to make a new tier queueable from the pipeline UI you also need to add a matching `run{Name}` boolean parameter in `azure-pipeline.yml` and a corresponding `if eq(parameters.run{Name}, true)` block in the tier-expansion list.

A pipeline run only provisions plans for tiers actually referenced by its resolved test cases — an all-Standard run creates one plan; a mixed-tier run creates one per distinct tier in use.

**SKU choice — why all three tiers share `P1v3`.** Umbraco Cloud Dedicated runs every plan tier on a single shared P1V3 App Service Plan pool (2 CPU / 8 GB RAM / 250 GB disk) and differentiates plans via per-site CPU/memory/disk *quotas* — quotas Azure doesn't let us replicate on a non-Cloud plan. Putting all three tiers on `P1v3` keeps the App Service-side variable matching Cloud's reality rather than introducing dedicated-plan SKUs Cloud doesn't actually use. The trade-off: our **Starter** numbers will look more optimistic than real Cloud Starter (no quota throttling). What we *can* differentiate cleanly is **SQL eDTU** (`S1` / `S2` / `S3`), which is also usually the dominant bottleneck for content-heavy Umbraco workloads — so the tier comparison is effectively a SQL-tier comparison until we find a way to model the App Service quotas.

## Scenarios

A **scenario** is an Umbraco-side configuration variant. The layout mirrors how Umbraco's own [acceptance test repo](https://github.com/umbraco/Umbraco-CMS) organises tests — a folder per scenario with an `AdditionalSetup/appsettings.json` carrying the configuration overlay:

```
loadtests/scenarios/
  Default/
    AdditionalSetup/
      appsettings.json     # {} — empty overlay
    scenario.yaml          # description; no profile overrides
  DeliveryApi/             # ships in the repo
    AdditionalSetup/
      appsettings.json     # enables Umbraco:CMS:DeliveryApi (PublicAccess on)
    scenario.yaml
  RedisCache/              # add when needed
    AdditionalSetup/
      appsettings.json     # Redis-specific Umbraco keys
    scenario.yaml          # optional load profile overrides
```

The shipped scenarios are **`Default`** (vanilla Umbraco — baseline) and **`DeliveryApi`** (headless mode with the Content Delivery API enabled and public access on; the locustfile probes the API at startup and splices Delivery-API tasks into the workload mix when the scenario is active, so non-DeliveryApi runs aren't polluted with Delivery-API samplers).

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

Some Umbraco features can't be flipped via `appsettings.json` alone — they need source-code changes (custom composers, builder-chain extensions, backoffice extensions). Mirroring how Umbraco's acceptance tests handle this, **any file in `AdditionalSetup/` other than `appsettings.json` is treated as a code overlay**: copied into the dotnet project tree before `dotnet build`, preserving relative paths.

(The shipped `DeliveryApi` scenario is itself an example: it needs *both* an `appsettings.json` overlay to enable the feature *and* a `Program.cs` overlay calling `.AddDeliveryApi()` in the builder chain to register the API's DI services. Without the code overlay, hitting `/umbraco/delivery/api/v2/content` returns 500 with `Unable to resolve service for type 'IRequestSegmentService'`.)

Another example — a hypothetical `CustomComposer` scenario that adds an event handler via composer:

```
loadtests/scenarios/CustomComposer/
  AdditionalSetup/
    appsettings.json                  # any related config
    Composers/MyComposer.cs           # custom Umbraco composer
```

When the install script deploys the scenario:

1. `dotnet new umbraco -n …` creates the project (with a default `Program.cs`).
2. The seeder package is added (`dotnet add package …`).
3. **Code overlay is applied**: every non-`appsettings.json` file under `AdditionalSetup/` is copied to the same relative path under the project root (e.g. `AdditionalSetup/Composers/MyComposer.cs` → `<project>/Composers/MyComposer.cs`, `AdditionalSetup/Program.cs` → `<project>/Program.cs` overwriting the template-generated one).
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
  users:     200    # overrides the profile's user count    when present
  spawnRate:  20    # overrides the profile's spawn rate    when present
  duration:  600    # overrides the profile's duration (s)  when present
```

All fields optional. A missing `scenario.yaml` (or an empty `loadProfile` block) means the case uses the queue-time pipeline-level defaults. The override resolution happens once in the validator — every downstream consumer (Terraform, Azure Load Testing, NDJSON publisher) sees the resolved values, not the override logic.

### Adding a new scenario

1. Create `loadtests/scenarios/{Name}/AdditionalSetup/appsettings.json` with your config overlay.
2. Optionally add `loadtests/scenarios/{Name}/scenario.yaml` with description + load profile overrides.
3. Add it to the `scenario` parameter's `values` list in `azure-pipeline.yml` so it appears in the queue dropdown.

That's it. No HCL or pipeline edits needed.

### Load Pattern

Every test follows a **ramp-up → steady-state → ramp-down** shape so the measurement window reflects sustained behaviour, not arrival shock:

- **Ramp-up** — Locust spawns VUs at the profile's `spawn rate` until all `users` are active (e.g. `standard` profile = 100 VUs at 10/s ≈ 10 s ramp).
- **Steady-state** — all VUs run their weighted task mix for the profile's `duration` (the metric window).
- **Ramp-down** — Azure Load Testing terminates VUs when the duration expires.

When comparing runs, only the steady-state samples are meaningful — ramp-up/down samples skew tail latency and should be filtered out in any deeper analysis.

### Workload distribution

`loadtests/locustfile.py` uses **weighted Locust tasks** so virtual users don't all hammer the same flow — they distribute across the seeded site the way real traffic would. Current weights (sum to 113):

| Task | Weight | Path pattern |
|---|---:|---|
| `homepage` | 5 | `/` |
| `section` | 10 | seeded section roots |
| `category` | 20 | seeded category pages |
| `page` | 30 | seeded content pages |
| `detail` | 35 | seeded detail/leaf pages |
| `media` | 5 | media URLs |
| `submit_contact_form` | 8 | `POST /umbraco/api/contactform/submit` (write path) |

The non-homepage tasks are **inventory-driven**: at test start, locust calls `/umbraco/api/seederstatus/inventory` to discover the actual URLs the seeder generated, so the same test code works against any seeder preset and any scenario without per-run config. Adjust weights in `locustfile.py` to model a different traffic mix.

### Cold-cache vs warm-cache testing

By default, the pipeline **warms up** the App Service (5-minute poll for `200` on `/`) before starting the load test, so measurements reflect steady-state cache-warm behaviour — the most stable comparison surface across tiers and versions.

Set `skipWarmup: true` to skip the warmup. The load test then hits a freshly-started App Service with cold caches, measuring the full delivery pipeline including initial cache population — useful for understanding cache warm-up cost, restart behaviour, and the front-edge of a request burst against a cold app.

## Results

The pipeline writes results to three places:

- **Azure Load Testing portal**: dashboard with client-side metrics (response time, throughput, errors) and server-side metrics (CPU, memory, network, disk). The Azure Load Testing resource lives in a **long-lived, shared resource group** (see "Infrastructure" below) so run history accumulates across pipeline runs. There's **one load test per scenario** (testId `umbraco-lt-{scenario}`), with every (version, tier) run nested under it — so the portal's "Compare runs" view lets you pick multiple runs and overlay their metrics natively. Each run is named `{umbracoVersion} {tier} #{buildId}`.
- **Pipeline artifacts**: per-case ZIP under `loadtest-results-{sanitised-testCaseId}` on the build, useful for forensic deep-dives. Expires with the pipeline's build retention policy.
- **History storage account** (long-lived): per-case NDJSON summary at `{scenario}/{major}/{umbracoVersion}/{tier}/{yyyy-MM-dd}_{buildId}/summary.ndjson` plus the raw artifact dump under `raw/`. Scenario is top-level because it defines what's *comparable* — different scenarios hit different endpoints / seed different data, so their numbers can't be compared directly. Within a scenario, prefix-listing maps to the natural pivots: `Default/17/` trends a major, `Default/17/17.0.0/` is all tiers in one build, `Default/17/*/Starter/` sweeps versions on one tier. Each row carries the full run metadata (commit, version, tier, scenario, SKUs, seeder preset, user count), so cross-run queries don't need joins.

NDJSON is ingestible directly by Azure Data Explorer, pandas, Postgres `COPY`, etc. — pick whatever query layer fits, the data shape stays the same.

### Comparing two runs

For the everyday "did this version/tier actually move the needle?" question, `scripts/compare-runs.ps1` pulls per-sampler aggregates straight out of history storage — no manual artifact download:

```powershell
# Version vs version on a fixed tier
./scripts/compare-runs.ps1 `
    -Scenario Default -Tier Standard `
    -BaselineVersion 17.0.0 -CandidateVersion 17.0.1 `
    -StorageAccountName $env:HISTORY_STORAGE_ACCOUNT `
    -ContainerName loadtest-history `
    -OutputPath compare.md

# Tier vs tier on a fixed version
./scripts/compare-runs.ps1 `
    -Scenario Default -Version 17.0.0 `
    -BaselineTier Starter -CandidateTier Pro `
    -StorageAccountName $env:HISTORY_STORAGE_ACCOUNT `
    -ContainerName loadtest-history
```

`-Aggregate latest` (default) compares the most recent run for each cell; `-Aggregate median5` compares the median across the last 5 runs (more stable on noisy tails). Auth: `az login` + permission to list keys on the history storage account (Storage Account Contributor or higher).

The script emits a markdown report with:
- **Per-sampler** breakdown (Detail, Page, Category, etc.) ordered by traffic share, with deltas bolded when they cross the significance threshold (default 10%)
- Run-id list per side so you can trace which runs contributed
- A "How to read this" footer (p95/p99 are the tier-discriminating metrics; max is single-sample noise; cached paths won't move regardless of tier)

History mode skips the aggregate-across-all-samplers row because true aggregate percentiles need raw request samples, which aren't preserved in the NDJSON summary. Per-sampler is the actionable view anyway.

**CSV fallback** — when history storage isn't accessible (local Locust runs, offline analysis, or a one-off comparison of pipeline-artifact CSVs):

```powershell
./scripts/compare-runs.ps1 `
    -BaselinePath  ./starter-17.0.0/engine1_results.csv `
    -CandidatePath ./standard-17.0.0/engine1_results.csv `
    -BaselineLabel "Starter 17.0.0" `
    -CandidateLabel "Standard 17.0.0"
```

CSV mode reads raw request samples and computes true aggregate percentiles, so it produces an additional **Aggregate** row that history mode can't.

### Trending across many runs

`scripts/compare-runs.ps1` answers "A vs B"; for "show me everything we've run on this scenario", use `scripts/show-trends.ps1`. It reads every `summary.ndjson` under a scenario's history-storage prefix and prints a markdown matrix of (Umbraco version × tier) → p95/p99/error% per sampler. Single-run cells use the run as-is; cells with 2+ runs show the **median plus stddev** so you can see at a glance whether the numbers are stable enough to baseline against.

The script authenticates via account-key — `az login` first, then it fetches the storage account key at runtime and uses `--account-key` for blob ops. Your user needs `Microsoft.Storage/storageAccounts/listKeys/action` on the history SA (Storage Account Contributor or higher).

```powershell
./scripts/show-trends.ps1 `
    -Scenario Default -Major 17 `
    -HistoryResourceGroup umbraco-loadtest-history-rg `
    -StorageAccountName $env:HISTORY_STORAGE_ACCOUNT `
    -ContainerName loadtest-history `
    -OutputPath trends.md
```

Optional `-Sampler Detail` filters to a single Locust task (handy when the matrix gets long). Output layout — one table per sampler:

```
| Version | Starter                       | Standard                    | Pro                         |
|---------|-------------------------------|-----------------------------|-----------------------------|
| 17.0.0  | 450 ±18 / 1200 ±60 (0.1%) n=4 | 264 ±9 / 807 ±42 (0%) n=4   | 144 ±7 / 821 ±55 (0%) n=4   |
| 17.0.1  | 420 / 1100 (0%)               | 250 / 780 (0%)              | 140 / 800 (0%)              |
```

Single-run cells are `p95 / p99 (err%)`; multi-run cells are `p95 ±stddev / p99 ±stddev (err%) n=K`. A small ±stddev across n≥3 runs is the green light to use those numbers as a regression baseline — see the next section.

### Establishing a baseline

Before turning on regression gating, you need to know what "stable" looks like. The protocol:

1. **Queue the same configuration 3× back-to-back.** Same Umbraco version, same scenario, same tiers, same profile, same SQL SKU. Don't change parameters between runs.
2. **Run `show-trends.ps1` and read the ±stddev.** A useful rule of thumb: if `stddev / median < 5%` on p95 across the 3 runs, the cell is stable enough to gate on. If it's wider, run a 4th and 5th — sometimes the first run is colder than the rest. If it's still wide after 5, the workload itself is too noisy and the gate would false-positive in CI.
3. **Once you have ≥3 stable runs in the bank**, `check-regression.ps1` will start scoring new runs against them automatically (it uses the most recent N prior runs as the baseline window).

Baselines decay — after a major Umbraco release, a tier-SKU shift, or a meaningful seeder/scenario change, the prior baseline numbers no longer reflect "what stable looks like" and you should re-baseline that cell. The script doesn't enforce this automatically; it's a judgment call on what counts as a "meaningful" change.

### Regression gating

`scripts/check-regression.ps1` reads the same NDJSON history, takes the latest run for each (version × tier × sampler) cell as the candidate, and compares it to the median of the previous N runs (default: last 5, minimum 3). Cells that exceed any threshold are flagged as regressions; the script exits non-zero so it can run as a pipeline gate.

```powershell
./scripts/check-regression.ps1 `
    -Scenario Default -Major 17 `
    -HistoryResourceGroup umbraco-loadtest-history-rg `
    -StorageAccountName $env:HISTORY_STORAGE_ACCOUNT `
    -ContainerName loadtest-history `
    -OutputPath regression-report.md
```

(Same auth requirement as `show-trends.ps1` — `az login` + Storage Account Contributor or higher on the history SA.)

Defaults:

| Threshold | Default | What it means |
|---|---|---|
| `-P95Threshold` | 10% | Latest p95 > baseline-median p95 × 1.10 → regression |
| `-P99Threshold` | 15% | Latest p99 > baseline-median p99 × 1.15 (wider band — tail latency is noisier) |
| `-ErrorAbsoluteThreshold` | 0.5pp | Latest error_rate is more than 0.5 percentage points above baseline median |
| `-MinBaselineRuns` | 3 | Cell needs at least this many prior runs to be gateable |
| `-BaselineWindow` | 5 | Cap on how many recent prior runs feed the baseline (keeps it sensitive to recent state) |

Cells with fewer than `-MinBaselineRuns` prior runs are reported as "insufficient baseline" and **never** trigger a fail — you can't regress against nothing. This means turning the gate on doesn't break the first few runs of a brand-new scenario or tier; the gate activates per-cell as baselines accrue.

Pass `-FailOnRegression $false` to render the report without failing (useful for "show me what would break if I turned this on").

The script is wired into the pipeline as the `regressionCheck` job after `runLoadTests`. It's permissive by default (cells with < `MinBaselineRuns` prior runs report "insufficient baseline" and exit 0), so it's safe to leave on from day one — the gate activates per-cell as baselines accrue.

### Infrastructure: ephemeral vs long-lived

The pipeline manages two separate resource groups:

| Resource group | Lifetime | Contents |
|---|---|---|
| `${prefix}-rg` (ephemeral) | Created and destroyed per pipeline run | App Service plans (one per used tier), App Services + SQL servers + databases (one per case) |
| `umbraco-loadtest-history-rg` (long-lived) | Created once, never deleted by the pipeline | Shared Azure Load Testing resource, storage account for results history |

The long-lived RG is provisioned idempotently at the start of every pipeline run by `scripts/ensure-history-infra.ps1` — first run creates it, subsequent runs no-op. Override the names via the `historyResourceGroup`, `historyLoadTestName`, `historyStorageAccount`, `historyContainer` pipeline variables (or pin them in a variable group) if multiple teams share the subscription. **The storage account name must be globally unique and 3-24 lowercase alphanumeric chars.**

## Pipeline Workflow

The pipeline runs in six stages. Stage boundaries are visible in the AzDO run summary so failures isolate cleanly: a failed `provision` stage tells you Terraform broke; a failed `loadTest` stage tells you the test itself broke. The `cleanup` stage runs on `succeededOrFailed()` so the ephemeral RG always gets torn down (or offered for manual keep) regardless of upstream outcome.

```
validateTestCases    Validate testCases JSON, read scenario folders, resolve load profile
                     (smoke / standard / stress) into seederPreset + engineInstances + VUs.

ensureHistoryInfra   Idempotent: shared Azure Load Testing resource + storage + container.
                     First run creates; subsequent runs no-op.

provision            checkResourceGroup → setup (init + validate + plan) → apply.
                     Provisions one App Service Plan per used tier, plus per-case App Services
                     and SQL DBs. Emits test_case_outputs map.

loadTest             verifyDeployments (only when skipLoadTests=true) OR runLoadTests, then
                     testSummary. Each case warms up, runs Locust on ALT, publishes results
                     to history storage and the build artifact.

regression           Compare candidate run against baseline-median; fail the pipeline when a
                     cell exceeds threshold AND has ≥3 prior runs. Skipped when
                     skipLoadTests=true.

cleanup              checkResourceGroupForCleanup → manualValidation (configurable window) →
                     deleteResourceGroup if rejected/cancelled/expired. Always runs.
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
2. Pick the **load profile** (`smoke` / `standard` / `stress`), **Umbraco version** (free text — prereleases ok), and **scenario** (defaults to `Default`).
3. Tick the **tiers** to run against (`runStarter` / `runStandard` / `runPro` — at least one). Defaults to Starter only.
4. Adjust the orthogonal knobs (region, prefix, cold start, skip load tests, validation window) only if you need to.
5. Wait for validation → ensure-history-infra → provisioning → load tests → regression check to complete.
6. Review results in Azure Load Testing portal, pipeline artifacts, and history storage NDJSON. The `regression-report` artifact has the post-run regression check output.
7. Approve or reject resource cleanup within the validation window (default 60 min).

### Smoke-testing changes

When iterating on scripts or Terraform, the full pipeline (~20-30 min) is too slow a feedback loop. Two cheaper modes:

- **Profile-only smoke** — `loadProfile=smoke`, `runStarter=true` (everything else default). Full stack runs (provision + build + seed + 60s load test + publish + regression check) in ~12-15 min. Use this when you've changed something that might affect the load-test path (Locust task, test config YAML, ALT integration).
- **Infra-only smoke** — `skipLoadTests=true` (with any profile + tier selection). Skips ALT entirely; runs validate → provision → install + seed → verify-deployments → cleanup. Use this when you've changed scripts/Terraform that affect provisioning or deployment but not load tests.

Both modes exercise the full ephemeral-infra cycle. The profile-only smoke mode runs the regression check too (a no-op until baselines accrue); the infra-only smoke mode skips it (no new run to check).

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

## Key metrics

Every per-case NDJSON row carries the metrics below (one row per Locust task, plus aggregate fields visible in the ALT portal). Use percentiles over averages — averages hide spikes.

**Client-side (from Locust / `engine1_results.csv` → NDJSON):**
- `request_count`, `failure_count`, `error_rate` — failure rate is the first thing to check; a fast-but-erroring run is not a successful run.
- `avg_ms`, `median_ms`, `p50_ms`, `p90_ms`, `p95_ms`, `p99_ms`, `min_ms`, `max_ms` — `p95` and `p99` are the tier-discriminating metrics. `max` is single-sample noise.
- `requests_per_sec` — throughput per task and aggregate.

**Server-side (Azure Load Testing portal, server metrics tab):**
- App Service: CPU %, memory %, network in/out, disk queue.
- SQL: DTU %, CPU %, log IO %, sessions.

Server-side ties directly to infrastructure sizing — when a tier saturates CPU or DTU at the profile's load, that's the ceiling of that SKU pair.

The publish step queries Azure Monitor for these metrics over the load-test window and injects mean/max into the NDJSON metadata (`plan_CpuPercentage_avg`, `sql_dtu_consumption_percent_max`, etc.) — so they appear alongside latency in `show-trends.ps1` / `check-regression.ps1` output without a separate query.

## Getting your first comparison

After "First-time setup" is done, the path from "infra works" to "I detected a regression" is:

**Step 1 — Establish a baseline.** Queue the same configuration 3× back-to-back. Pick the one you actually care about; don't try to baseline everything at once.

```
Pipeline parameters for the 3 baseline runs:
  umbracoVersion: 17.0.0
  scenario:       Default
  runStarter:     true   (others false — start narrow)
  loadProfile:    standard
  sqlSkuOverride: Auto
  skipWarmup:     false
  skipLoadTests:  false
```

Wait for all 3 to finish, then approve cleanup on each.

**Step 2 — Check stability.** Run `show-trends.ps1` and look at the `±stddev` on p95.

```powershell
./scripts/show-trends.ps1 `
    -Scenario Default -Major 17 `
    -StorageAccountName $env:HISTORY_STORAGE_ACCOUNT `
    -ContainerName loadtest-history
```

Cells with `n=3` and `stddev / median < 5%` on p95 are stable enough to baseline. If a cell is wider than that, queue 2 more runs and re-check; the first run is sometimes cold relative to the others. If it's still wide after 5, the workload itself is too noisy for that cell to be a useful baseline target.

**Step 3 — Queue a candidate.** Once stable, queue the run you actually want to evaluate — typically a different `umbracoVersion`, or the same version with a `sqlSkuOverride` to test SQL-tier effects.

```
Pipeline parameters for the candidate:
  umbracoVersion: 17.0.1   (← the change being evaluated)
  scenario:       Default
  runStarter:     true
  loadProfile:    standard
  ...
```

**Step 4 — The pipeline auto-checks.** The `regressionCheck` job at the end of the run compares the candidate's per-sampler stats against the median of the prior 5 runs in that cell. The pipeline fails if any cell exceeds the thresholds (default p95 +10%, p99 +15%, error_rate +0.5pp). The full breakdown is in the `regression-report` build artifact.

**Step 5 — Spot-check manually.** For deeper investigation (or comparing two specific runs out-of-band), use `compare-runs.ps1` in history mode:

```powershell
./scripts/compare-runs.ps1 `
    -Scenario Default -Tier Starter `
    -BaselineVersion 17.0.0 -CandidateVersion 17.0.1 `
    -StorageAccountName $env:HISTORY_STORAGE_ACCOUNT `
    -ContainerName loadtest-history `
    -Aggregate median5 -OutputPath compare.md
```

`-Aggregate median5` compares medians across 5 runs each side — the right call when you have stable baselines and want to filter out single-run noise.

**Step 6 — Interpret deltas.** The report bolds cells crossing the significance threshold (default 10%). Skim the bold cells. Common patterns:

- **All read paths regressed by ~10-30%** — likely a code change in the content/render hot path.
- **One sampler regressed but others didn't** — likely a code change scoped to that endpoint.
- **p99 regressed but p95 didn't** — usually a tail-latency issue (GC, lock contention, transient SQL slowness). p99 is noisier; rule out before raising alarm.
- **All samplers up uniformly + SQL `dtu_consumption_percent_max` near 100%** — SQL DTU saturation, not code. Try `sqlSkuOverride=S3` and re-run.
- **All samplers up + `plan_CpuPercentage_max` near 100%** — App Service saturation. Same diagnostic question, different lever (App Service tier).

The `regression-report` artifact + the per-sampler table from `compare-runs.ps1` together usually tell you whether to **investigate the code** or **revisit the infra sizing**.

## Roadmap

Status of in-progress and not-yet-started work.

### Planned scenarios

The pipeline ships with the `Default` scenario only. The following scenarios are planned baseline coverage; each will live as its own folder under `loadtests/scenarios/` with an `appsettings.json` overlay (and code overlay where needed) plus extensions to `locustfile.py`.

**Front-end user journeys**
- **Homepage and navigation flow** — land on the homepage, navigate menus, browse pages.
- **Content listing with pagination** — step through paginated listing pages that query and render multiple content items.
- **Media-heavy pages** — request pages with multiple images and media items.
- **Member registration and login** — register, log in/out, navigate authenticated member areas. (Blocked on the seeder package adding member front-end views — currently it creates members but not the login/register MVC views.)

**Backoffice operations**
- **Save and publish** — modify a content node and publish.
- **Save complex document type** — save a doctype with many properties + many related content items.
- **Content tree browsing** — navigate and expand the content tree at scale.
- **Bulk operations** — publish or unpublish many nodes in batch.
- **Multiple backoffice users** — concurrent editorial operations.

**Mixed traffic**
- **Frontend browsing + concurrent backoffice editing** — front-end load with simultaneous editorial save/publish. CMS workloads see this combination in production and it can shift cache invalidation patterns and DB contention in ways neither pure-frontend nor pure-backoffice tests will surface.

### Surface server-side metrics in `show-trends` / `check-regression`

Server-side metrics (`plan_CpuPercentage_avg`, `sql_dtu_consumption_percent_max`, etc.) are now captured into NDJSON metadata by `publish-load-test-results.ps1` over the load-test window. They appear alongside latency for any consumer that queries the NDJSON directly. Still pending: `show-trends.ps1` and `check-regression.ps1` only render the latency fields today. Extending them to also surface server-side cells (e.g. a "DTU saturation" matrix alongside p95) and to gate on saturation thresholds (e.g. "fail when SQL DTU max > 95%") is the natural next iteration. Per-tier saturation thresholds become first-class regression conditions when this lands.

### Deeper resource-exhaustion monitoring

Beyond the metrics above, the harder-to-see failure modes need richer instrumentation:

- **App / process** — thread pool exhaustion, request queue length.
- **Network** — sockets in TIME_WAIT, HTTP.sys queue length.
- **Disk / filesystem** — IO queue depth, throughput.

These need Azure Monitor diagnostic settings on the App Service or the App Service Diagnostics extension; not wired up yet.

### Thresholds

`check-regression.ps1` is wired into the pipeline as a post-load-test job (`regressionCheck`). It runs after every load-test run and either passes (no regressions or insufficient baseline) or fails the pipeline (real regression detected). The mechanism is **always on** but starts permissive: each (scenario × version × tier × sampler) cell needs ≥ 3 prior runs before it gates — until then, the cell is reported as "insufficient baseline" and contributes no fails. As baselines accrue per the "Establishing a baseline" protocol, the gate activates per-cell automatically. The post-run `regression-report` build artifact captures the full per-cell breakdown.

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

