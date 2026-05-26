# Umbraco Load Testing Infrastructure

A starting point for load testing Umbraco CMS on Azure using Terraform, Locust, and Azure Load Testing. The focus is establishing CMS performance baselines, but the infrastructure, pipeline, and test framework are designed to be reusable — other teams (Cloud, DXP, Workflow, Commerce, …) can fork the repo, add their own packages and configuration, and build team-specific scenarios on top of the same foundation.

## Goals

Establish repeatable CMS performance baselines across Umbraco versions, infrastructure tiers (Cloud-aligned `P0v3 → P3v3` apps × `20/50/100/200` DTU SQL), and scenarios — and ship a reusable pipeline + harness other teams can extend without rebuilding infra. Pipeline-failing thresholds are deferred until baselines exist (the regression-check stage will activate per-cell as ≥3 stable runs accrue).

## Overview

This project provisions isolated Azure environments for arbitrary combinations of **(Umbraco version × infrastructure tier × scenario × workload)**, seeds them with test data using [Umbraco.Cms.TestDataSeeder](https://www.nuget.org/packages/Umbraco.Cms.TestDataSeeder/), and runs load tests via Azure Load Testing service. Two workload modes ship: **frontend** (Locust — anonymous reads + contact-form submissions against rendered pages and the Delivery API) and **backoffice** (JMeter — authenticated backoffice writes: SaveContent, PublishContent, SaveDocumentType, MemberLogin). See "Workload modes" below.

**Supported Umbraco versions: v13–v18 (subject to seeder availability).** Each major maps to a specific .NET runtime (see [Umbraco-major → .NET-runtime map](#umbraco-major--net-runtime-map) below). Today only **v17** has a published `Umbraco.Cms.TestDataSeeder` build (`17.0.0-beta.2`); v13–v16 and v18 queues fail at validation with a clear message until the seeder ships for those majors. Update the maps in `scripts/resolve-run-config.ps1` (validator-side) and `Terraform/modules/umbraco/scripts/install-umbraco-cms-on-appservice.ps1` (install-side) in lockstep when a new seeder version ships.

The `DeliveryApi` scenario is **v17+ only** — its `Program.cs` overlay uses v17's builder shape. The validator rejects the `DeliveryApi` + < v17 combination before provisioning. Use the `Default` scenario for older majors.

Locust (frontend) and JMeter (backoffice) tests both execute on Azure Load Testing's managed infrastructure (dedicated Standard_D4d_v4 VMs), not on the pipeline agent. This ensures consistent, reliable performance measurements.

A pipeline run is parameterised by a list of **test cases**. Each case picks:

- **Umbraco/.NET version pair** (e.g. `17.0.0` on `v10.0`)
- **Infrastructure tier** — `Starter` / `Standard` / `Pro` / `Enterprise`, defined in [`loadtests/tiers.json`](loadtests/tiers.json) (App Service Plan SKU + per-DB DTU cap inside a Standard-tier Elastic Pool)
- **Scenario** — a folder under `loadtests/scenarios/` containing the Umbraco `appsettings.json` overlay for that scenario plus optional `scenario.yaml` load-profile overrides

Cases on the same tier in one run share an App Service Plan; cases on different tiers each get their own. Tests within a run run sequentially (one App Service hot at a time) so each measurement gets the full plan capacity.

## Prerequisites

- Azure subscription with appropriate permissions. The pipeline service principal needs:
  - Standard create/manage rights on the ephemeral and history resource groups (Contributor is enough for resources).
  - **`Microsoft.Storage/storageAccounts/listKeys/action`** on the history storage account — Storage Account Contributor (or any role that includes `listKeys/action`) is enough. Downstream scripts (`publish-load-test-results.ps1`, `_history-helpers.ps1`) fetch the account key at runtime and authenticate with `--account-key`. RBAC + `--auth-mode login` would be a stricter alternative but requires `Microsoft.Authorization/roleAssignments/write` for the SP, which is a heavier permissions ask.
  - **`Microsoft.Authorization/roleAssignments/write`** on the history resource group (or specifically on the Data Collection Rule once it exists) — `ensure-monitoring-infra.ps1` grants the same SP "Monitoring Metrics Publisher" on the DCR so it can POST to the Logs Ingestion API. User Access Administrator on the history RG is sufficient.
  - **Directory read** in Microsoft Entra ID — the pipeline calls `az ad sp show` to resolve its own object ID for the role grant above. Default tenants allow this for any authenticated principal; locked-down tenants may need an explicit `Directory Readers` role assignment on the SP.
- Azure DevOps organization with:
  - Service connection to Azure (`terraform-umbraco-load-testing-az-connection`)
  - Variable group `umbraco-loadtest-history` with at minimum: `historyResourceGroup`, `historyLocation`, `historyLoadTestName`, `historyStorageAccount` (override the placeholder `loadtestchangeme` with a globally-unique 3-24 lowercase alphanumeric value), `historyContainer`.
- Terraform >= 1.13.3 (pinned at 1.13.3 in CI; pipelines install via TerraformInstaller@0)
- PowerShell Core (pwsh) 7.3+ — earlier versions silently swallow native command failures (`dotnet build` errors etc.) because `$ErrorActionPreference = "Stop"` doesn't apply to native exit codes; 7.3 introduced `$PSNativeCommandUseErrorActionPreference` which the install script sets.

## First-time setup

A new team forking this project should:

1. **Pick a globally-unique storage account name** (3-24 lowercase alphanumeric chars). This will host the long-lived run history. Override `historyStorageAccount` in the variable group with this value — the placeholder `loadtestchangeme` is rejected by `ensure-history-infra.ps1`.
2. **Create the AzDO variable group** `umbraco-loadtest-history` with the five history variables above.
3. **Configure the service principal** with the permissions listed in Prerequisites — Contributor on the subscription (or scoped narrower) is sufficient.
4. **Queue the pipeline once.** The first run creates the long-lived history infra (RG, ALT resource, storage account, container) **and the monitoring infra** (Log Analytics workspace, custom table, DCR, Workbook) alongside the per-case provisioning. The Workbook URL is printed in the `ensureMonitoringInfra` stage log — pin it to your Azure portal dashboard.
5. **(Local-dev users)** `az login` and verify you can list keys for the history storage account — `show-trends.ps1` / `check-regression.ps1` / `compare-runs.ps1` (history mode) run locally need the same `listKeys/action` the pipeline SP uses:
   ```bash
   az storage account keys list -n <your-history-storage-account> -g umbraco-loadtest-history-rg --query "[0].keyName" -o tsv
   ```
   If that command works, the analysis tools will work. If it fails with "AuthorizationFailed", grant yourself Storage Account Contributor (or higher) on the SA scope.
6. **Queue 3-5 baseline runs** with the same configuration to populate history (see "Establishing a baseline" below). Until cells have ≥ 3 prior runs, the pipeline's regression-check stage reports "insufficient baseline" and exits 0 — it's safe to enable from day one.

> ⚠️ Before queueing your first non-default run, skim the [Pitfalls](#pitfalls) section — security, name-length, overlay-precedence, and cleanup gotchas live there.

**History storage scales sub-linearly thanks to a lifecycle policy.** `ensure-history-infra.ps1` tiers blobs from Hot → Cool after 30 days (override via `-LifecycleCoolAfterDays`). Cool tier is ~3× cheaper than Hot for storage, retrieval is still instant, and the per-read cost is negligible at PS-tool / Workbook query frequency.

Archive tier transition is **disabled by default** (`-LifecycleArchiveAfterDays = 0`) because the policy filter is coarse — it applies to every blob in the container, including the small `summary.ndjson` files the PS analysis tools read. Archive saves another ~3× on storage but takes **hours** to rehydrate; reads against year-old `summary.ndjson` would fail with HTTP 409 until rehydration completes. Enable Archive only if you've segregated raw zips into a separate prefix and tightened the policy filter, or you're OK with the rehydration delay.

## Project Structure

```
├── azure-pipeline.yml           # Main load test pipeline (manual queue)
├── README.md
│
├── dashboards/
│   └── loadtest.workbook.json   # Azure Workbook: Trends / Tiers / Versions / Compare / Runs / Glossary over LoadTestSummary_CL
│
├── templates/
│   └── load-test-job.yml        # Per-case load test template (testCaseId lookup pattern)
│
├── scripts/
│   ├── resolve-run-config.ps1          # Pipeline entry: resolves queue-time params + invokes validator
│   ├── prepare-test-cases.ps1          # Validator: validates testCases, flattens scenario appsettings,
│   │                                   #            resolves load profile, emits testCasesJson + resolvedTestCases
│   ├── ensure-history-infra.ps1        # Idempotently provisions long-lived RG, Azure Load Testing, storage
│   ├── ensure-monitoring-infra.ps1     # Idempotently provisions Log Analytics + custom tables + DCR/DCE
│   ├── deploy-workbook.ps1             # Idempotently deploys/updates the Azure Workbook from JSON
│   ├── backfill-monitoring.ps1         # Replay older blob-storage summary.ndjson into Log Analytics
│   ├── generate-loadtest-config.ps1    # Per-case ALT YAML config (testId, appComponents, failureCriteria)
│   ├── stop-all-app-services.ps1       # Pre-test and end-of-run sweep: stop App Services in the case set
│   ├── publish-load-test-results.ps1   # Exports per-test NDJSON + raw artifacts to history storage
│   ├── compare-runs.ps1                # Markdown delta report between two runs (CSV or history)
│   ├── show-trends.ps1                 # (version × tier) p95/p99/error% matrix from history NDJSON
│   ├── check-regression.ps1            # Compare latest run vs baseline-median; non-zero exit on regression (gate)
│   ├── parameterize-jmx.js             # One-time rewriter: convert hardcoded JMeter Arguments to ${__P()} refs
│   ├── _helpers.ps1                    # Shared helpers dot-sourced by other scripts (Get-Pct, Get-StorageAccountKey, …)
│   └── _history-helpers.ps1            # Shared helpers for the history-NDJSON consumers (dot-sourced)
│
├── loadtests/
│   ├── _helpers.py              # Shared workload mixin + inventory/Delivery API probes used by scenario locustfiles
│   ├── scenarios/<Name>/locustfile.py  # Scenario-specific workload, imports from _helpers
│   ├── tiers.json               # Tier catalog (Starter / Standard / Pro / Enterprise → SKUs + DTU caps)
│   └── scenarios/
│       ├── Default/
│       │   ├── AdditionalSetup/
│       │   │   └── appsettings.json     # {} — identity overlay
│       │   ├── jmeter/                  # backoffice workload (JMeter) — see "Workload modes" below
│       │   │   ├── v13/                 # one .jmx file per backoffice test (ViewHomePage, SaveContent, …)
│       │   │   └── v17/                 # v18 reuses v17/ via fallback
│       │   ├── locustfile.py            # frontend workload (Locust)
│       │   └── scenario.yaml
│       └── DeliveryApi/
│           ├── AdditionalSetup/
│           │   ├── appsettings.json     # enables Umbraco:CMS:DeliveryApi
│           │   └── Program.cs           # registers .AddDeliveryApi() in builder chain
│           ├── locustfile.py
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

The queue UI splits into three concerns: **what to test**, **which tiers to test it on**, and **how hard to test**. Each lives on its own knob so you can mix freely (e.g. "stress profile against Standard only" or "smoke profile against all four tiers").

**What to test:**

| Parameter | Description | Default | Options |
|-----------|-------------|---------|---------|
| `umbracoVersion` | Umbraco CMS version. Free-text — accepts prereleases (`17.0.0-rc.1`, `17.1.0-beta.2`). The validator accepts v13, v17, v18 today (the majors with a published `Umbraco.Cms.TestDataSeeder` build — v18 reuses the v17 seeder as a fallback); v14/v15/v16 fail validation with a "seeder hasn't shipped" message. The major segment maps to the .NET runtime automatically (see table below). | 17.0.0 | free text |
| `scenario` | Scenario folder name (must match a folder under `loadtests/scenarios/`) | Default | extend the `values` list when adding scenarios |
| `workload` | Which workload to run. `frontend` runs the scenario's `locustfile.py` (anonymous reads + contact form). `backoffice` runs every `.jmx` under `scenarios/{scenario}/jmeter/v{major}/` sequentially (authenticated backoffice writes). See "Workload modes" below. The validator rejects backoffice when the chosen scenario has no `jmeter/v{major}/` folder. | frontend | `frontend`, `backoffice` |

**Which tiers:**

| Parameter | Description | Default |
|-----------|-------------|---------|
| `runStarter` | Run the Starter tier (P0v3 app, 20 DTU SQL) | true |
| `runStandard` | Run the Standard tier (P1v3 app, 50 DTU SQL) | false |
| `runPro` | Run the Pro tier (P2v3 app, 100 DTU SQL) | false |
| `runEnterprise` | Run the Enterprise tier (P3v3 app, 200 DTU SQL) | false |

At least one tier must be selected — the validator fails the run if all are unchecked.

**Load profile (intensity):**

| Profile | Seeder preset | VUs | Spawn rate | Duration | Engines |
|---|---|---|---|---|---|
| `smoke` | Small | 20 | 10/s | 60s | 1 |
| `standard` | Medium | 50 | 10/s | 300s | 1 |
| `stress` | Large | 300 | 50/s | 600s | 2 |

The profile only encodes load intensity — the same profile can drive any combination of tiers. Tuning a profile is a single-place edit to the inline `switch` in `azure-pipeline.yml`'s "Resolve profile + validate scenario" step.

**.NET runtime is derived, not selected.** The prep step maps the Umbraco major version → required .NET runtime; the pipeline installs the matching SDK and Terraform sets the App Service runtime accordingly. Extend the map in `scripts/resolve-run-config.ps1` (and the seeder-version map in the install script) when a new Umbraco major ships.

#### Umbraco-major → .NET-runtime map

| Umbraco major | App Service runtime | SDK installed by pipeline |
|---:|:---:|:---:|
| 13 | `v8.0` | `8.x` |
| 14 | `v8.0` | `8.x` |
| 15 | `v9.0` | `9.x` |
| 16 | `v9.0` | `9.x` |
| 17 | `v10.0` | `10.x` |
| 18 | `v10.0` | `10.x` |

**Multi-version comparisons:** queue the pipeline once per version. ALT's Compare runs view aggregates across pipeline runs (testId is per-scenario, not per-pipeline-run).

**Run configuration (orthogonal knobs):**

| Parameter | Description | Default | Options |
|-----------|-------------|---------|---------|
| `azureRegion` | Azure region | West Europe | West Europe, North Europe, East US, West US 2 |
| `resourcePrefix` | Resource name prefix (max 16 chars) | umbraco-loadtest | — |
| `skipWarmup` | Skip warmup (test cold-start / cache warm-up behaviour) | false | true, false |
| `validationTimeoutMinutes` | How long resources stay alive after tests | 60 | 15, 30, 60, 120, 240 |
| `poolDtuOverride` | Force every case onto a specific per-DB DTU cap (decouples DB sizing from tier) | Auto | Auto, 10, 20, 50, 100, 200 |
| `appSkuOverride` | Force every case onto a specific App Service Plan SKU (decouples app sizing from tier) | Auto | Auto, P0v3, P1v3, P2v3, P3v3 |
| `seederPresetOverride` | Force every case onto a specific TestDataSeeder preset (decouples content size from load profile) | Auto | Auto, Small, Medium, Large, Massive |

**Pool DTU override.** When set to a value other than `Auto`, every test case in the run uses the same per-DB DTU cap regardless of the tier's default — useful for "is SQL actually the bottleneck?" experiments. Default caps are Starter→20, Standard→50, Pro→100, Enterprise→200 (see `tiers.json`). The Elastic Pool's eDTU capacity is sized automatically to the smallest valid Standard pool that can hold a DB at the chosen cap.

**App SKU override.** Counterpart to `poolDtuOverride` on the app side. When set to a value other than `Auto`, every test case uses the same App Service Plan SKU regardless of the tier's default — useful for "is the app actually the bottleneck?" experiments. Default SKUs are Starter→P0v3, Standard→P1v3, Pro→P2v3, Enterprise→P3v3.

**Seeder preset override.** Decouples content size from the load profile. `Auto` keeps the existing coupling (smoke→Small, standard→Medium, stress→Large); explicit values unlock off-diagonal combinations like Massive content + smoke load or Small content + stress load, and are the only way to reach the Massive preset. Approximate seeder times: Small ~10 min, Medium ~30 min, Large ~60 min, Massive ~120 min.

The validator (`scripts/prepare-test-cases.ps1`) catches typos, missing scenario folders, and duplicate `(umbraco, tier, scenario)` triples *before* any Azure resource is provisioned. It also enforces sensible ranges on the load profile values the profile resolver hands it (`userAmount` 1–1000, `spawnRate` 1–100, `testDuration` 30–7200 seconds).

## Tiers

`loadtests/tiers.json` is the **single source of truth** for tier names + SKUs. Both Terraform (provisioning) and the PowerShell validator read this same file:

```json
{
  "tiers": {
    "Starter":    { "app_sku": "P0v3", "dtu_max": 20  },
    "Standard":   { "app_sku": "P1v3", "dtu_max": 50  },
    "Pro":        { "app_sku": "P2v3", "dtu_max": 100 },
    "Enterprise": { "app_sku": "P3v3", "dtu_max": 200 }
  }
}
```

`dtu_max` is the per-DB DTU cap inside the tier's Elastic Pool. Terraform computes the pool's eDTU capacity from this cap (smallest valid Standard pool size that can hold a DB at the cap).

Add a tier by adding a key here. Both the validator and Terraform will pick it up automatically — but to make a new tier queueable from the pipeline UI you also need to add a matching `run{Name}` boolean parameter in `azure-pipeline.yml` and a corresponding `if eq(parameters.run{Name}, true)` block in the tier-expansion list.

A pipeline run only provisions plans + pools for tiers actually referenced by its resolved test cases — an all-Standard run creates one App Service Plan + one SQL server + one Elastic Pool; a mixed-tier run creates one per distinct tier in use.

**SKU choice — why each tier gets a dedicated P-SKU.** Umbraco Cloud differentiates plans via dedicated App Service Plan SKUs (P0v3 / P1v3 / P2v3 / P3v3 across the four tiers), not via per-site quotas on a shared pool — so we provision one dedicated plan per tier in use with the same SKU progression. SQL side mirrors Cloud exactly: Standard-tier Elastic Pools with per-DB DTU caps of 20 / 50 / 100 / 200 DTUs for Starter / Standard / Pro / Enterprise. The two `*Override` queue-time parameters let an operator decouple app sizing from SQL sizing for bottleneck diagnosis (e.g. "P3v3 app + 20 DTU SQL" isolates the SQL contribution).

## Scenarios

A **scenario** is an Umbraco-side configuration variant. The layout mirrors how Umbraco's own [acceptance test repo](https://github.com/umbraco/Umbraco-CMS) organises tests — a folder per scenario, optionally with an `AdditionalSetup/appsettings.json` carrying the configuration overlay. A scenario with no Umbraco config to override (like `Default`) can either omit `AdditionalSetup/` entirely or ship an empty `{}`:

```
loadtests/scenarios/
  Default/
    AdditionalSetup/
      appsettings.json     # {} — identity overlay
    locustfile.py
    scenario.yaml          # description; no profile overrides
  DeliveryApi/             # ships in the repo
    AdditionalSetup/
      appsettings.json     # enables Umbraco:CMS:DeliveryApi (PublicAccess on)
      Program.cs           # code overlay: registers .AddDeliveryApi()
    locustfile.py
    scenario.yaml
  RedisCache/              # add when needed
    AdditionalSetup/
      appsettings.json     # Redis-specific Umbraco keys
    locustfile.py
    scenario.yaml          # optional load profile overrides
```

The shipped scenarios are **`Default`** (traditional customer — rendered pages + media + write path) and **`DeliveryApi`** (headless customer — Content Delivery API + media + write path, no rendered-page traffic). Each scenario ships its own `locustfile.py` next to its `AdditionalSetup/` and declares its tasks explicitly, so the workload that runs for a given scenario is fully visible in that one file. Shared building blocks (inventory probe, Delivery API probe, `pick_url` helper) live in `loadtests/_helpers.py` and are imported by each scenario's locustfile.

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

Long prerelease tags eat into the budget — see [Pitfalls › Name length](#name-length-long-umbraco-prereleases-break-the-60-char-app-service-cap).

### Sampler naming

A **sampler** is one operation within a scenario — a `@task` method in a Locust file, or an HTTP Request label in a JMeter `.jmx`. The workbook keys cells by `(scenario × umbraco_version × infra_tier × scenario_name)` and treats sampler names as opaque strings. Two consequences:

- A renamed sampler spawns a new cell. Historical baseline for the old name doesn't transfer — the regression gate restarts at zero for the new name.
- Two scenarios that share a sampler name (e.g. `BackofficeV13` and `BackofficeV17` both with a `Login` sampler) line up in the Compare tab's per-sampler delta view. Different names for the same operation (`Login` vs `BackofficeLogin`) won't.

Reserved character: sampler names **must not contain `__`** — that's the cell-key delimiter parsed by `check-regression.ps1` and `_history-helpers.ps1`.

For cross-version test plans where the same operation is implemented against two different APIs (the obvious case is backoffice — v13's `/umbraco/backoffice/UmbracoApi/...` vs v17+'s `/umbraco/management/api/v1/...`), agreeing on sampler labels up front is the cheapest discipline. A suggested canonical set for authenticated / backoffice flows:

| Sampler | Operation |
|---|---|
| `Login` | Authenticate (any flavour — session cookie, OAuth token, etc.) |
| `ContentList` | List or page through the content tree |
| `ContentRead` | Read one content item by id |
| `ContentSave` | Save (unpublished) one content item |
| `ContentPublish` | Publish one content item |
| `ContentUnpublish` | Unpublish one content item |
| `MediaList` | List media folders or items |
| `MediaUpload` | Upload one media file |
| `UserList` | List users (admin-only) |
| `Search` | Full-text search query |

Front-end (anonymous) scenarios continue to use the existing convention from `Default` / `DeliveryApi` (`Homepage`, `Section`, `Category`, `Page`, `Detail`, `Media`, `ContactFormSubmit`, `DeliveryApiList`, `DeliveryApiItem`).

Locust takes the sampler name from the method name (or the `name=` kwarg on `client.get/post`); JMeter takes it from the HTTP Request element's name. Same string lands in `LoadTestSummary_CL.scenario_name` either way — and from there into every workbook surface that filters or groups by sampler.

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

Overlay keys win over base keys — see [Pitfalls › Overlay precedence](#overlay-precedence-a-scenario-can-clobber-base-settings) for what that can clobber if you're not deliberate.

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

Optional load profile overrides:

```yaml
description: "Free-text description (folder-level docs only; not read by code)"   # optional
loadProfile:                                                                       # optional whole block
  users:     200    # overrides the profile's user count    when present
  spawnRate:  20    # overrides the profile's spawn rate    when present
  duration:  600    # overrides the profile's duration (s)  when present
```

All fields optional. The validator reads only `loadProfile.*`; `description` is a folder-level docs note and isn't consumed anywhere. A missing `scenario.yaml` (or an empty `loadProfile` block) means the case uses the queue-time pipeline-level defaults. Override resolution happens once in the validator — every downstream consumer (Terraform, Azure Load Testing, NDJSON publisher) sees the resolved values, not the override logic.

### Adding a new scenario

1. If your scenario needs an Umbraco config overlay, create `loadtests/scenarios/{Name}/AdditionalSetup/appsettings.json` (and any code overlay files alongside, e.g. `Program.cs`). A scenario with no overlay either omits the folder or ships `AdditionalSetup/appsettings.json` with `{}` (the validator handles both).
2. Create `loadtests/scenarios/{Name}/locustfile.py` declaring the scenario's workload (import probes / `pick_url` from `_helpers.py` as needed).
3. Optionally add `loadtests/scenarios/{Name}/scenario.yaml` with description + load profile overrides.
4. Add `{Name}` to the `scenario` parameter's `values:` list in `azure-pipeline.yml` so it appears in the queue-time dropdown.

The validator (`scripts/prepare-test-cases.ps1`) is the source-of-truth check — it enumerates the folders on every run, prints the available list at the top of its log, and rejects unknown names with a "did you mean?" hint. The dropdown is a queue-time discovery aid; no HCL or downstream-pipeline edits are needed.

### Load Pattern

Every test follows a **ramp-up → steady-state → ramp-down** shape so the measurement window reflects sustained behaviour, not arrival shock:

- **Ramp-up** — Locust spawns VUs at the profile's `spawn rate` until all `users` are active (e.g. `standard` profile = 50 VUs at 10/s ≈ 5 s ramp).
- **Steady-state** — all VUs run their weighted task mix for the profile's `duration` (the metric window).
- **Ramp-down** — Azure Load Testing terminates VUs when the duration expires.

When comparing runs, only the steady-state samples are meaningful — ramp-up/down samples skew tail latency and should be filtered out in any deeper analysis.

### Workload distribution

Each scenario's locustfile declares its `@task` methods explicitly, so the workload that runs for a given scenario is fully visible in that one file. The Default scenario (traditional content-browsing customer) uses **weighted Locust tasks** so virtual users don't all hammer the same flow — they distribute across the seeded site the way real traffic would. Current weights (sum to 113):

| Task | Weight | Path pattern |
|---|---:|---|
| `homepage` | 5 | `/` |
| `section` | 10 | seeded section roots |
| `category` | 20 | seeded category pages |
| `page` | 30 | seeded content pages |
| `detail` | 35 | seeded detail/leaf pages |
| `media` | 5 | media URLs |
| `submit_contact_form` | 8 | `POST /umbraco/api/contactform/submit` (write path) |

The non-homepage tasks are **inventory-driven**: at test start, locust calls `/umbraco/api/seederstatus/inventory` to discover the actual URLs the seeder generated, so the same test code works against any seeder preset without per-run config. Tasks raise (visible as a 100%-error task in the report) when a bucket is empty — no silent fallbacks, so a broken seeder or misconfigured scenario surfaces loudly instead of distorting the workload. Adjust weights in a scenario's own `locustfile.py` to change that scenario's traffic mix; the DeliveryApi scenario is structured the same way but exercises the Content Delivery API endpoints instead of rendered pages.

### Deterministic URL selection

`loadtests/_helpers.py` seeds Python's `random` at module import (fixed seed `42` by default), so `random.choice()` over the seeded URL inventory follows the same sequence across runs. Cell-to-cell variance from "this run happened to hit Detail-7 a lot, that run hit Detail-23" drops out — leaving infrastructure jitter as the dominant signal in run-to-run deltas (which is the comparison you actually want for regression checks). Set the `LOCUST_RANDOM_SEED` env var to a different integer if you specifically want randomised content selection (e.g. to validate that the harness ISN'T sensitive to URL choice). Caveat: each Locust engine/worker process re-seeds at import, so full request-by-request reproducibility isn't promised; the aggregate URL distribution per run is what stays stable.

### Workload modes: frontend (Locust) vs backoffice (JMeter)

The `workload` queue-time parameter selects which load harness runs against the provisioned App Service. The two modes are intentionally separate — they exercise different code paths (rendering pipeline vs management API), have different auth models (anonymous vs OAuth/PKCE), and produce different perf signatures that aren't meaningfully comparable head-to-head.

**Frontend (`workload: frontend`, default).** Single Locust test plan (`loadtests/scenarios/{scenario}/locustfile.py`) runs against the App Service. Mix is weighted `@task` methods (Homepage / Section / Category / Page / Detail / Media / submit_contact_form). One ALT testId per scenario (`umbraco-lt-{scenario}`); one TestRun per (version × tier) pipeline run.

**Backoffice (`workload: backoffice`).** For each `.jmx` under `loadtests/scenarios/{scenario}/jmeter/v{major}/`, the pipeline runs a separate ALT test sequentially on the same warm App Service. v18 deployments fall back to `jmeter/v17/` (matching the seeder's v17→v18 reuse). Default shipped backoffice tests:

| .jmx | Hits | Auth |
|---|---|---|
| `ViewHomePage` | `GET /` | none (sanity / baseline) |
| `MemberLogin` | `POST /umbraco/api/memberlogin/login` (frontend member endpoint) | form + anti-forgery (currently unhandled — known limitation, see below) |
| `SaveContent` | `/umbraco/management/api/v1/.../authorize` then `POST /content/PostSave` | OAuth + PKCE (admin) |
| `SaveAndPublishContent` | same as SaveContent + publish step | same |
| `SaveDocumentType` | schema mutation API | same |
| `PublishContent` (v17+ only) | publish flow | same |

Each `.jmx` gets its own ALT testId (`umbraco-lt-{scenario}-bo-{jmxStem}`), its own metric-capture window, its own blob path (`{scenario}/{major}/{version}/{tier}/{date}_{buildId}/{JmxName}/`), and its own row in `LoadTestSummary_CL` tagged with `jmeter_test_name`. Iterations are sequential within one tier-job and skip cleanly when a `.jmx` isn't present for the resolved major (e.g. `PublishContent` on v13).

**State across the loop is intentionally shared.** Iterations run against the same warm App Service without re-seeding between them. SaveContent.jmx creates content; SaveDocumentType.jmx modifies schema; PublishContent.jmx runs against the cumulative state. This mirrors mixed-workload backoffice use, but means later iterations don't measure clean isolated performance. To compare a single `.jmx` cleanly across runs, treat each `jmeter_test_name` row as its own series.

**Seeder member discovery.** Before the backoffice loop, the pipeline queries `GET /umbraco/api/seederstatus/inventory?includeMemberPassword=true` and extracts the actual seeded member count + password. These are written to the per-iteration `.properties` file as `totalOfMember` and `member_password` so MemberLogin.jmx's Groovy preprocessor picks an existing seeded member rather than guessing. Discovery falls back to defaults (`TestMember_`, count=30, `Test1234!`) if the endpoint is unreachable, so the loop still runs — just with degraded MemberLogin hit-rate. The discovered prefix is emitted as a pipeline variable (`seededMemberPrefix`) for log visibility but isn't consumed by the .properties file (the .jmx Groovy hardcodes the prefix; documented limitation below).

**Run cost / timing.** Each `.jmx` iteration ≈ test duration + ~3 minutes ALT overhead (engine provisioning + result download). At `standard` profile (5-min tests) × 6 .jmx files, the backoffice loop is ~50 minutes per tier; 4 tiers in parallel still completes in ~50 minutes wall-clock. At `smoke` (1-min tests), ~25 min per tier.

#### Known backoffice limitations

These are documented for the next person — fixes are in scope for follow-up work, not in any of the current commits.

- **MemberLogin always fails 100%.** `MemberLoginController.Login` has `[ValidateAntiForgeryToken]` but the `.jmx` doesn't extract or send `__RequestVerificationToken`. Every POST returns 400 before reaching the controller. Fix requires either (a) adding a `RegexExtractor` to the `.jmx` after the GET, or (b) switching the `.jmx` to the JSON endpoint `/umbraco/api/memberauth/login` (which is anti-forgery-exempt — see the [TestDataSeeder README](https://www.nuget.org/packages/Umbraco.Cms.TestDataSeeder/) for the table of endpoints).
- **`TestUser_*` accounts have no password.** `UserSeeder.cs` creates them but never calls `SetPasswordAsync`. The only backoffice account that can authenticate is the Terraform unattended-install admin (`loadtest@example.invalid` / `LoadTest123!`), so all auth-requiring `.jmx` files use that single credential. The `.jmx` files happen to use a property named `backoffice_username` for this — misleading but accurate to what works.
- **Member prefix is hardcoded in the Groovy preprocessor.** `MemberLogin.jmx` builds `member_username = "TestMember_<random index>"` with `"TestMember_"` as a string literal. The seeder default IS `TestMember_`, so this works in practice — but if someone customizes `Configuration:Prefixes:Member`, MemberLogin would target a non-existent user pattern. Fix is straightforward: add `memberPrefix` to the .jmx User Defined Variables as `${__P(memberPrefix,TestMember_)}` and update the Groovy to read it.

#### Adding a new backoffice `.jmx` test

1. Drop the `.jmx` under `loadtests/scenarios/{Scenario}/jmeter/v{major}/` (one copy per Umbraco major you want to test against).
2. Add the file's stem (no extension) to the `jmxNames` default list at the top of `templates/load-test-job.yml`. The order matters — iterations run in this order, and later iterations see state mutations from earlier ones.
3. Run `node scripts/parameterize-jmx.js` to rewrite hardcoded `<server>`/`<port>`/`<numberOfThread>`/auth-cred values to `${__P()}` property references. Idempotent — re-runs skip already-parameterized values. If your `.jmx` introduces a new parameter that the harness should override at runtime, add it to the `OVERRIDABLE` set in that script.
4. Decide which credentials it needs:
   - **No auth** (e.g. a `GET /something-public`): no `.properties` entry needed.
   - **Member login**: use `member_username` (built by Groovy from `totalOfMember`) and `member_password` (sourced from seeder discovery).
   - **Backoffice admin**: use `backoffice_username` and `backoffice_password` (Terraform unattended-install admin).
5. Queue with `workload: backoffice`. The new `.jmx` runs as an additional iteration.

### Cold-cache vs warm-cache testing

By default, the pipeline **warms up** the App Service (5-minute poll for `200` on `/`) before starting the load test, so measurements reflect steady-state cache-warm behaviour — the most stable comparison surface across tiers and versions.

Set `skipWarmup: true` to skip the warmup. The load test then hits a freshly-started App Service with cold caches, measuring the full delivery pipeline including initial cache population — useful for understanding cache warm-up latency, restart behaviour, and the front-edge of a request burst against a cold app.

## Debugging failed runs

The pipeline has six stages and most failures isolate cleanly to one of them. Start by looking at which stage failed in the AzDO run summary, then follow the playbook for that stage. Common symptoms by stage:

### `validateTestCases` failed

Queue-time validator (`scripts/prepare-test-cases.ps1` + `scripts/resolve-run-config.ps1`) rejects the configuration before any Azure resource is provisioned. Common causes and exact log messages:

- **Unsupported Umbraco major**: "Umbraco.Cms.TestDataSeeder hasn't shipped a build for major N yet…" — extend the maps in `resolve-run-config.ps1` AND `Terraform/modules/umbraco/scripts/install-umbraco-cms-on-appservice.ps1` in lockstep.
- **Unknown scenario**: "Scenario 'X' has no folder under loadtests/scenarios/" — folder names are case-strict.
- **Backoffice + scenario without .jmx**: "Workload=backoffice selected but scenario 'X' has no jmeter/vN/ folder" — drop a `.jmx` under `loadtests/scenarios/{X}/jmeter/v{N}/` or pick a different workload.
- **All tier checkboxes off**: "At least one tier must be selected" — tick at least one of `runStarter` / `runStandard` / `runPro` / `runEnterprise`.

### `provision` failed

Terraform fan-out broke. Look at the `Apply (testCase X)` job's logs.

- **`A resource with the ID … already exists`**: a previous run's ephemeral RG wasn't cleaned up. Either delete it manually in the portal or pick a different `resourcePrefix`.
- **App Service name too long**: provisioning fails ~10 minutes in with an Azure error about the 60-char cap. Shorten the prefix (≤16 chars), the scenario name (≤15), or the Umbraco prerelease tag. See [Name length](#name-length-long-umbraco-prereleases-break-the-60-char-app-service-cap) in Pitfalls.
- **`dotnet build` failed**: the scenario's code overlay (Program.cs, Composers, etc.) has a compile error. Check the install-script log under `local-exec`.
- **Seeder timeout**: install script polls `/umbraco/api/seederstatus/status` and gives up after the per-preset cap (10/30/60/120 min for Small/Medium/Large/Massive). Pick a smaller preset or raise the cap in the install script.
- **`az webapp stop` returned 503**: transient — the install script retries 3× with 5/10/20s backoff and fails the apply only after all retries exhaust. Re-queue.

### `loadTest` failed (or completed with errors)

The ALT run finished but data quality is questionable.

- **`displayName must be a string of length between 2 to 50`**: scenario + .jmx name combined overflows 50 chars. `generate-loadtest-config.ps1` enforces this with a defensive check that errors out earlier — if it still slips through, shorten the scenario name.
- **`Test window unusable (Ns)` warning in publish**: ALT fast-failed (engine provisioning, auth, validation) so the wall-clock window is < 30s and metric query is skipped. Look for the AzureLoadTest@1 step's error a few lines up.
- **`Could not query seeder inventory … using fallback defaults`**: the "Discover seeder member state" step couldn't reach the App Service. MemberLogin.jmx will run with `totalOfMember=30` and `password=Test1234!` regardless of what the seeder actually created — degraded hit-rate. Usually means the App Service isn't fully started; investigate the Start App Service step.
- **`Posting N row(s) to Log Analytics` followed by silence in the Workbook**: new custom tables take 5–10 minutes to surface after first ingest. Wait, then re-query. If still empty after 30 min, check Service Principal has Monitoring Metrics Publisher on the DCR.

### `regression` failed

`scripts/check-regression.ps1` flagged a regression OR reported a baseline-evolution event.

- **"Cell `<sampler>` insufficient baseline (N < 3 runs)"**: not a failure — exits 0. Means this cell needs more runs before the gate has teeth. See "Establishing a baseline".
- **"Cell `<sampler>` regressed: p95 ratio 1.12 > 1.10"**: candidate p95 exceeded 110% of baseline-median. Check whether it's a real perf regression, infrastructure variance, or a baseline-decay event (after Umbraco major bump or SKU change, the old baseline doesn't apply).

### `cleanup` was rejected / timed out

By design — `validationTimeoutMinutes` is the window operators have to inspect the ephemeral environment. After it elapses (or you reject explicitly), Terraform destroys the RG.

If you need the environment longer: re-queue with a higher `validationTimeoutMinutes` (max 240). To make a deployment permanent: queue with `validationTimeoutMinutes=240`, then before it expires, copy whatever you need to a different RG. There's no "promote to permanent" path — by design, every load-test environment is intended to be ephemeral.

### Where to find raw data when the dashboard says nothing

Even when the Workbook is empty, the pipeline writes results to **four** places. In rough order of timeliness / detail:

1. **Pipeline build artifacts** (immediate, per-build) — under "Artifacts" on the AzDO run. Each tier × .jmx gets a `loadtest-results-{safeTestCaseId}` artifact with the raw `results.zip` from ALT.
2. **Azure Load Testing portal** (immediate, per-run) — `https://portal.azure.com → umbraco-loadtest-runs`. Run name format `{version} {tier} {jmxName} #{buildId}` for backoffice runs, `{version} {tier} {poolDtuMax}DTU #{buildId}` for frontend.
3. **History storage account** (immediate, long-lived) — `{scenario}/{major}/{version}/{tier}/{date}_{buildId}/[{jmxName}/]summary.ndjson` plus raw `engine*_results.csv` under `raw/`.
4. **Log Analytics workspace** (5–10 min lag on first ingest, ~1 min thereafter) — `LoadTestSummary_CL` for per-sampler aggregates, `LoadTestSeries_CL` for per-minute metric series.

If LA is empty but blob storage has data, run `scripts/backfill-monitoring.ps1` to replay the blobs into LA (dedupes against existing rows by run_id).

### Re-extracting a result locally

To inspect a single run's raw CSV without re-running:

```powershell
# Download the build artifact from AzDO
# Or pull from history storage:
az storage blob download `
    --account-name $env:HISTORY_STORAGE_ACCOUNT --account-key $key `
    --container-name results `
    --name "Default/17/17.0.0/Starter/2026-05-21_264394/ViewHomePage/raw/results.zip" `
    --file results.zip

Expand-Archive results.zip -DestinationPath extracted/
# extracted/engine1_results.csv is JMeter format: timeStamp,elapsed,label,...
```

## Results

The pipeline writes results to four places:

- **Azure Load Testing portal**: dashboard with client-side metrics (response time, throughput, errors) and server-side metrics (CPU, memory, network, disk). The Azure Load Testing resource lives in a **long-lived, shared resource group** (see "Infrastructure" below) so run history accumulates across pipeline runs. There's **one load test per scenario** (testId `umbraco-lt-{scenario}`), with every (version, tier) run nested under it — so the portal's "Compare runs" view lets you pick multiple runs and overlay their metrics natively. Each run is named `{umbracoVersion} {tier} {poolDtuMax}DTU #{buildId}` — the per-DB DTU cap is in the name so override runs (e.g. `Standard 100DTU`) are distinguishable from default-pairing runs (`Standard 50DTU`) in the portal's Compare view.
- **Pipeline artifacts**: per-case ZIP under `loadtest-results-{sanitised-testCaseId}` on the build, useful for forensic deep-dives. Expires with the pipeline's build retention policy.
- **History storage account** (long-lived): per-case NDJSON summary at `{scenario}/{major}/{umbracoVersion}/{tier}/{yyyy-MM-dd}_{buildId}/summary.ndjson` plus the raw artifact dump under `raw/`. Scenario is top-level because it defines what's *comparable* — different scenarios hit different endpoints / seed different data, so their numbers can't be compared directly. Within a scenario, prefix-listing maps to the natural pivots: `Default/17/` trends a major, `Default/17/17.0.0/` is all tiers in one build, `Default/17/*/Starter/` sweeps versions on one tier. Each row carries the full run metadata (commit, version, tier, scenario, SKUs, seeder preset, user count), so cross-run queries don't need joins.
- **Log Analytics workspace** (long-lived): the same NDJSON rows mirrored into the `LoadTestSummary_CL` custom table for KQL querying, plus per-minute Azure Monitor datapoints (plan CPU/memory, SQL DTU/log-write, HTTP 4xx/5xx) in the companion `LoadTestSeries_CL` table feeding the Workbook's per-run drill-down panel. Backoffice runs tag every row with `jmeter_test_name` so per-`.jmx` slices stay queryable. The Workbook (see "Dashboard" below) reads from both tables. Blob storage remains source of truth — Log Analytics is a queryable mirror.

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

Pass `-NoFailOnRegression` to render the report without failing (useful for "show me what would break if I turned this on").

The script is wired into the pipeline as the `regressionCheck` job after `runLoadTests`. It's permissive by default (cells with < `MinBaselineRuns` prior runs report "insufficient baseline" and exit 0), so it's safe to leave on from day one — the gate activates per-cell as baselines accrue.

### Infrastructure: ephemeral vs long-lived

The pipeline manages two separate resource groups:

| Resource group | Lifetime | Contents |
|---|---|---|
| `${prefix}-rg` (ephemeral) | Created and destroyed per pipeline run | App Service plans (one per used tier), App Services + SQL servers + databases (one per case) |
| `umbraco-loadtest-history-rg` (long-lived) | Created once, never deleted by the pipeline | Shared Azure Load Testing resource, storage account for results history, Log Analytics workspace + custom table + DCR/DCE for the Workbook, the Workbook itself |

The long-lived RG is provisioned idempotently at the start of every pipeline run by `scripts/ensure-history-infra.ps1` (storage / ALT) and `scripts/ensure-monitoring-infra.ps1` (Log Analytics / DCR / Workbook role grant) — first run creates, subsequent runs no-op. Override the names via the `historyResourceGroup`, `historyLoadTestName`, `historyStorageAccount`, `historyContainer`, `historyWorkspaceName`, `historyDceName`, `historyDcrName` pipeline variables (or pin them in a variable group) if multiple teams share the subscription. **The storage account name must be globally unique and 3-24 lowercase alphanumeric chars.**

## Pipeline Workflow

The pipeline runs in seven stages. Stage boundaries are visible in the AzDO run summary so failures isolate cleanly: a failed `provision` stage tells you Terraform broke; a failed `loadTest` stage tells you the test itself broke. The `cleanup` stage runs on `always()` so the ephemeral RG gets torn down (or offered for manual keep) on every outcome — including pipeline cancellation.

```
validateTestCases    Validate testCases JSON, read scenario folders, resolve load profile
                     (smoke / standard / stress) into seederPreset + engineInstances + VUs.

ensureHistoryInfra   Idempotent: shared Azure Load Testing resource + storage + container.
                     First run creates; subsequent runs no-op.

ensureMonitoringInfra Idempotent: Log Analytics workspace + custom table + DCR/DCE + Workbook.
                     Exposes the Logs Ingestion target as cross-stage variables.

provision            checkResourceGroup → setup (init + validate + plan) → apply.
                     Provisions one App Service Plan per used tier, plus per-case App Services
                     and SQL DBs. Emits test_case_outputs map.

loadTest             runLoadTests: each case warms up, runs Locust on ALT, publishes results
                     to history storage, the build artifact, and Log Analytics.

regression           Compare candidate run against baseline-median; fail the pipeline when a
                     cell exceeds threshold AND has ≥3 prior runs.

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

The seeder preset is **run-level** — applied uniformly to every case. (A scenario *can* override it via the `appsettings.json` overlay key `Umbraco.Cms.TestDataSeeder__Options__Preset` if you really need it per-case — see [Pitfalls › Overlay precedence](#overlay-precedence-a-scenario-can-clobber-base-settings).)

## Usage

### Running via Azure Pipelines

1. Run the pipeline manually from Azure DevOps.
2. Pick the **load profile** (`smoke` / `standard` / `stress`), **Umbraco version** (free text — prereleases ok), and **scenario** (defaults to `Default`).
3. Tick the **tiers** to run against (`runStarter` / `runStandard` / `runPro` / `runEnterprise` — at least one). Defaults to Starter only.
4. Adjust the orthogonal knobs (region, prefix, cold start, skip load tests, validation window) only if you need to.
5. Wait for validation → ensure-history-infra → ensure-monitoring-infra → provisioning → load tests → regression check to complete.
6. Review results in Azure Load Testing portal, pipeline artifacts, and history storage NDJSON. The `regression-report` artifact has the post-run regression check output.
7. Approve or reject resource cleanup within the validation window (default 60 min).

### Smoke-testing changes

When iterating on scripts or Terraform, the full pipeline (~20-30 min) is too slow a feedback loop. Run a **profile-only smoke**: `loadProfile=smoke`, `runStarter=true` (everything else default). Full stack runs (provision + build + seed + 60s load test + publish + regression check) in ~12-15 min. Exercises the full ephemeral-infra cycle and the load-test path on the smallest seeder preset.

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
locust -f scenarios/Default/locustfile.py --host https://<app-service-url>
# Or run the DeliveryApi scenario:
# locust -f scenarios/DeliveryApi/locustfile.py --host https://<app-service-url>
# Open http://localhost:8089 to configure and start the test
```

## Key metrics

Every per-case NDJSON row carries the metrics below (one row per Locust task, plus aggregate fields visible in the ALT portal). Use percentiles over averages — averages hide spikes.

**Client-side (from Locust / `engine1_results.csv` → NDJSON):**
- `request_count`, `failure_count`, `error_rate` — failure rate is the first thing to check; a fast-but-erroring run is not a successful run.
- `avg_ms`, `p50_ms`, `p90_ms`, `p95_ms`, `p99_ms`, `min_ms`, `max_ms` — `p95` and `p99` are the tier-discriminating metrics. `max` is single-sample noise.
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
  poolDtuOverride: Auto
  skipWarmup:     false
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

**Step 3 — Queue a candidate.** Once stable, queue the run you actually want to evaluate — typically a different `umbracoVersion`, or the same version with a `poolDtuOverride` to test SQL-tier effects.

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
- **All samplers up uniformly + SQL `dtu_consumption_percent_max` near 100%** — SQL DTU saturation, not code. Try `poolDtuOverride=100` (or 200) and re-run.
- **All samplers up + `plan_CpuPercentage_max` near 100%** — App Service saturation. Same diagnostic question, different lever (App Service tier).

The `regression-report` artifact + the per-sampler table from `compare-runs.ps1` together usually tell you whether to **investigate the code** or **revisit the infra sizing**.

## Dashboard

`dashboards/loadtest.workbook.json` is an Azure Workbook that queries `LoadTestSummary_CL` in Log Analytics and offers six views:

- **Trends** — chronological per-run chart of the chosen metric (p95 / p99 / avg / error rate / RPS / server CPU peak / DB load peak), one line per `(scenario × version × tier)`; side-by-side latency + resource-pressure charts share a run-indexed x-axis for direct visual correlation of code-bound vs infra-bound symptoms; matrix table below with median ±stddev and a plain-language **Stability** label per cell (*stable / moderate / noisy / few runs*) flagging cells where a small regression threshold would be lost in run-to-run noise. Sampler filter is multi-select.
- **Tiers** — pick scenario + version, see latest run per tier as a bar chart + a Capacity-verdict table with **Headroom** and a **Bottleneck** column naming the hottest resource and its peak (e.g. `Database load 92%`). Tier rows sort by capacity rank (Starter → Standard → Pro → Enterprise). Answers "what do I get for upgrading the tier — and what saturated first?"
- **Versions** — pick scenario + tier, see per-sampler median latency grouped by Umbraco version. Answers "did this version regress on this tier?"
- **Compare** — pick two runs + Δ% threshold; per-sampler delta table with red/green conditional formatting; server-side delta block with a **Note** column distinguishing "no change" from "no data". Failed runs (`no_metrics`) are excluded from the run pickers.
- **Runs** — filtered run list with **Bottleneck** + regression-verdict columns; pick a run from the drill dropdown to see the regression breakdown (which specific samplers flagged), per-sampler latency detail, **and per-minute resource-pressure charts** (% metrics and HTTP error counts on separate axes) sourced from a companion `LoadTestSeries_CL` table — answers "when *in* the run did p99 spike?" / "did SQL DTU saturate before App CPU?" — the questions the summary scalars can't.
- **Glossary** — vocabulary reference for every column / verdict / metric used in the other tabs.

Global filter bar (Workspace, time range, Scenario / Version / Tier dropdowns) scopes Trends / Compare / Runs. Tiers and Versions have their own scoped pickers (Tiers is the cross-tier view, Versions is the cross-version view). Workbook URLs encode the filter state, so links are shareable.

Auth piggybacks on Azure RBAC: anyone with **Reader** on the Log Analytics workspace (or its parent RG) can view the Workbook. No separate identity to manage.

> **Single-team scope today.** The Workbook GUID, the `LoadTestSummary_CL` table, and the workspace itself are shared resources with no per-team partitioning. If multiple teams ever fork this and target the same subscription, they'll need to override `historyWorkspaceName` / `historyDceName` / `historyDcrName` (already supported) **and** pass a fork-specific `-WorkbookId` to `deploy-workbook.ps1` to avoid clobbering each other's dashboard customisations. Row-level filters per team aren't implemented — anyone with workspace Reader sees every team's data.

### Setup

Nothing to run manually. The pipeline's `ensureMonitoringInfra` stage runs every time and idempotently provisions:

1. **Log Analytics workspace** (`historyWorkspaceName`, default `umbraco-loadtest-laws`)
2. **Custom tables**:
   - `LoadTestSummary_CL` — one row per (run × sampler), plus regression-check + metadata-only marker rows. The Workbook's primary table.
   - `LoadTestSeries_CL` — one row per (run × metric × minute), populated from the same Azure Monitor data that `LoadTestSummary_CL`'s `*_avg / *_max` scalars come from but kept un-aggregated. Powers the per-run drill-down chart.
3. **Data Collection Endpoint + Rule** for the Logs Ingestion API (a single DCR carries both stream declarations)
4. **Monitoring Metrics Publisher** role on the DCR for the pipeline service principal (resolved automatically from the service connection — no manual SP-ID lookup)
5. **The Workbook itself**, re-applied from `dashboards/loadtest.workbook.json` so changes to the file ship to Azure on the next pipeline run

After the first pipeline run, the printed Workbook URL is in the `ensureMonitoringInfra` stage log (look for "Workbook deployed" — the URL line below it). Pin the Workbook to your Azure portal dashboard for one-click access. First-time data takes ~5–10 minutes to surface in a brand-new custom table.

If you want to override the resource names (e.g. multiple teams sharing one subscription), set `historyWorkspaceName`, `historyDceName`, `historyDcrName` in the `umbraco-loadtest-history` variable group.

### Manual deploy (rare)

You can run either script manually if you need to provision monitoring outside a pipeline run, or push a Workbook tweak without queueing the full pipeline:

```powershell
./scripts/ensure-monitoring-infra.ps1 `
    -HistoryResourceGroup umbraco-loadtest-history-rg `
    -HistoryLocation "West Europe" `
    -WorkspaceName umbraco-loadtest-laws `
    -DceName umbraco-loadtest-dce `
    -DcrName umbraco-loadtest-dcr `
    -IngestPrincipalId (az ad sp show --id <pipeline-sp-app-id> --query id -o tsv)

./scripts/deploy-workbook.ps1 `
    -HistoryResourceGroup umbraco-loadtest-history-rg `
    -HistoryLocation "West Europe" `
    -WorkspaceName umbraco-loadtest-laws
```

### Maintenance

**Prereqs both scripts assume**: `az` CLI logged in (`az login`), pwsh 7.3+.

**Iterating on the Workbook** — edit `dashboards/loadtest.workbook.json` directly, or edit in the portal's Advanced Editor and paste the result back. Re-run `deploy-workbook.ps1` to push. The deploy uses a stable GUID (`-WorkbookId` parameter) so re-runs update in place.

**Schema changes** — if you add a field in `publish-load-test-results.ps1`, mirror it in the `$columns` array in `ensure-monitoring-infra.ps1` and re-run that script. The DCR PUT is an in-place schema update; existing data is preserved. Fields without a matching column are dropped at ingestion (no failure).

**Backfilling old runs** — the Workbook only sees what's been ingested into Log Analytics. Anything in blob storage from before the monitoring infra existed (or any run whose original publish step succeeded the blob upload but failed the Logs Ingestion call) is invisible to the Workbook. Replay it with:

```powershell
./scripts/backfill-monitoring.ps1 `
    -HistoryResourceGroup umbraco-loadtest-history-rg `
    -StorageAccountName <history-sa> `
    -ContainerName loadtest-history `
    -WorkspaceName umbraco-loadtest-laws `
    -DceName umbraco-loadtest-dce `
    -DcrName umbraco-loadtest-dcr
```

Idempotent by default — queries existing `run_id`s in the table and skips blobs whose run is already there. `-Force` re-ingests everything (creates duplicates; use only after a teardown).

**Access control** — grant `Log Analytics Reader` (or any role that includes read on the workspace) to anyone who needs to view the Workbook. Revoke by removing the role assignment.

**Teardown** — remove the Workbook + monitoring without affecting load-test history:

```powershell
az resource delete --ids "/subscriptions/<sub>/resourceGroups/umbraco-loadtest-history-rg/providers/Microsoft.Insights/workbooks/<workbookId>"
az monitor data-collection rule delete -n umbraco-loadtest-dcr -g umbraco-loadtest-history-rg
az monitor data-collection endpoint delete -n umbraco-loadtest-dce -g umbraco-loadtest-history-rg
az monitor log-analytics workspace delete -n umbraco-loadtest-laws -g umbraco-loadtest-history-rg --yes
```

The history storage account, container, and ALT all stay untouched.

### Troubleshooting

- **Workbook loads but tables/charts are empty.** Check the Log Analytics workspace directly: `LoadTestSummary_CL | take 50`. If empty, `publish-load-test-results.ps1` isn't reaching the Logs Ingestion API — check pipeline log for the "Posting N row(s) to Log Analytics" line. Most common cause: the SP doesn't have Monitoring Metrics Publisher on the DCR (re-run `ensure-monitoring-infra.ps1` to repair).
- **First-ever ingest after table creation appears to do nothing.** New custom tables take 5–10 minutes for ingestion to surface. Wait, then re-query.
- **Permission denied opening the Workbook.** Grant `Log Analytics Reader` (or Contributor on the workspace) to the user.
- **`deploy-workbook.ps1` fails with "Resource not found" on the workspace.** Run `ensure-monitoring-infra.ps1` first; the deploy script needs the workspace to set its `sourceId`.

## Roadmap

Status of in-progress and not-yet-started work.

### Planned scenarios

The pipeline currently ships with the `Default` and `DeliveryApi` scenarios. The following are planned baseline coverage; each will live as its own folder under `loadtests/scenarios/` with an `appsettings.json` overlay (and code overlay where needed) plus a scenario-specific `locustfile.py` that imports from `loadtests/_helpers.py`.

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

## Pitfalls

Things that have caught people out at least once. Skim before queueing your first non-default run.

### Approved-kept RGs are not auto-cleaned

The cleanup behaviour:

- **Reject the manual validation** (or let it time out, default 60 min) → the ephemeral RG is deleted automatically.
- **Cancel the pipeline run** → still deletes, because `cleanup` runs `condition: always()`.
- **Approve (Resume) the manual validation to keep resources for inspection** → the RG is **not** deleted, ever, by the pipeline. You have to `az group delete -n ${prefix}-rg --yes` yourself when you're done.

So when you click Resume, write yourself a reminder. There's no scheduled reaper, no auto-expiry beyond the validation window, and a forgotten approved-kept RG persists until you (or the next pipeline run, which will fail with "resource group already exists" and surface the orphan) catches it.

### Security: hardcoded backoffice creds on a public-internet App Service

The Terraform unattended-install config bakes a known admin login (`loadtest@example.invalid` / `LoadTest123!`) into every App Service so any team member can poke around in the backoffice. The App Services are public-internet by default (no IP allowlist) and the hostname is predictable from the test case ID. The risk window is the lifetime of the ephemeral RG — keep `validationTimeoutMinutes` to the minimum you actually need, and prefer rejecting cleanup explicitly when you're done.

This is fine for ephemeral load-test environments with no real data; it would not be fine for anything else. If you fork this for a workload that handles real data, replace the hardcoded creds with a per-run random password and add an IP allowlist (or vnet integration).

### Overlay precedence: a scenario can clobber base settings

A scenario's `AdditionalSetup/appsettings.json` is **merged into the base App Service `app_settings` with overlay keys winning on collision**. That's deliberate flexibility, but a sufficiently aggressive overlay can stomp on `Umbraco__CMS__Unattended__*` (breaks unattended install) or `Umbraco.Cms.TestDataSeeder__Options__Preset` (overrides the run-level seeder preset). Be deliberate about what your overlay touches.

### Name length: long Umbraco prereleases break the 60-char App Service cap

Azure App Service names are capped at 60 chars. The computed name is `${prefix}-appservice-${umbraco}-${tier}-${scenario}` (≤16 + 12 + ≤length(version) + ≤length(tier) + ≤15 + connectors). Long Umbraco prerelease tags (`17.0.0-rc.1.beta.2`) eat into the budget. Terraform fails the run early via a `lifecycle.precondition` with a clear error message, but you'd rather not get there — prefer release versions (`X.Y.Z`) and shorten scenario names if running prereleases on a long-named tier.

### Capacity: Massive preset is slow

The seeder timeout for Massive is **120 minutes per case** (10s polling × 720 attempts) — the worst-case ceiling, not the typical seed time (30-60 min per the Data Seeder Presets table). A full 4-tier Massive run can take ~6-8 hours in the apply stage alone before any load testing happens. The Terraform Apply task has a 720-minute budget, so this fits, but you're using most of it.

Practical guidance: use Massive when you specifically need the data volume. For most baselining and comparison work, Medium (the `standard` profile) is the right grain — and runs in a fraction of the time.

## Troubleshooting

### Common Issues

**Preflight fails with "tier 'X' is not in tiers.json"**
- Check `loadtests/tiers.json` — the tier catalog. Either fix the typo in your `testCases` entry or add the tier to the catalog.

**Preflight fails with "scenario folder not found"**
- The scenario folder must exist at `loadtests/scenarios/{Name}/`. Folder lookup is case-strict on every agent — the validator will suggest the closest match if the casing differs. `AdditionalSetup/appsettings.json` is optional (only needed for scenarios with an Umbraco config overlay).

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
git ls-files 'loadtests/**/locustfile.py' 'loadtests/_helpers.py' | ForEach-Object { python -m py_compile $_ }
yamllint -d "{rules: {document-start: disable, line-length: disable, truthy: disable}}" loadtests/scenarios/
git ls-files '*.json' | ForEach-Object { Get-Content -LiteralPath $_ -Raw | ConvertFrom-Json | Out-Null }
```

Running these locally catches the common typos (trailing commas in the Workbook JSON, unescaped `$` in PowerShell, indentation in scenario yaml) without burning a pipeline run.

## Azure resource tagging

Every provisioned resource carries:

| Tag | Where | Value |
|---|---|---|
| `project` | All | `umbraco-loadtest` |
| `managed_by` | Ephemeral resources | `terraform` |
| `managed_by` | Long-lived history infra | `ensure-script` |
| `build_id` | Ephemeral resources | `$(Build.BuildId)` from the pipeline (or `local` for hand runs) |
| `tier` | App Service Plan | The tier name (`Starter` / `Standard` / `Pro` / `Enterprise`) |
| `test_case_id` | App Service, SQL Server, SQL DB | The full testCaseId |
| `umbraco_version` | App Service, SQL Server, SQL DB | The Umbraco CMS version |
| `scenario` | App Service, SQL Server, SQL DB | The scenario folder name |

Azure Portal can group/filter resources by any of these tags — `managed_by` separates per-run ephemeral resources from the long-lived history infra.

Pre-existing untagged history infra (created before this change) won't be retroactively tagged. Either re-tag manually (`az group update -n umbraco-loadtest-history-rg --set tags.project=umbraco-loadtest tags.managed_by=ensure-script`) or recreate the RG.

