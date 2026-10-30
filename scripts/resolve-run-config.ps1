# Resolve queue-time pipeline parameters into a normalised run configuration,
# emit pipeline output variables, and invoke the test-case validator.
#
# Local invocation for testing:
#   pwsh -File scripts/resolve-run-config.ps1 `
#       -Profile standard -UmbracoVersion 17.0.0 -Scenario Default `
#       -RunStarter True -RunStandard False -RunPro False -RunEnterprise False `
#       -PoolDtuOverride Auto -AppSkuOverride Auto `
#       -WorkspaceRoot $PWD

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)] [ValidateSet('smoke', 'standard', 'stress', 'ramp')] [string]$Profile,
    [Parameter(Mandatory = $true)] [string]$UmbracoVersion,
    [Parameter(Mandatory = $true)] [string]$Scenario,
    # Bool-shaped flags pass through as strings — AzDO interpolates booleans as
    # 'True'/'False', and PowerShell's strict [bool] binder refuses to coerce
    # quoted strings (only $true/$false/1/0). Compared against 'True' below.
    [Parameter(Mandatory = $true)] [string]$RunStarter,
    [Parameter(Mandatory = $true)] [string]$RunStandard,
    [Parameter(Mandatory = $true)] [string]$RunPro,
    [Parameter(Mandatory = $true)] [string]$RunEnterprise,
    [Parameter(Mandatory = $true)] [string]$PoolDtuOverride,
    [Parameter(Mandatory = $true)] [string]$AppSkuOverride,
    [Parameter(Mandatory = $true)] [ValidateSet('Auto', 'Small', 'Medium', 'Large', 'Massive')] [string]$SeederPresetOverride,
    [Parameter(Mandatory = $true)] [ValidateSet('frontend', 'backoffice', 'client')] [string]$Workload,
    [Parameter(Mandatory = $true)] [string]$WorkspaceRoot,
    # Skips the package-feed lookup for $UmbracoVersion. For tests and offline
    # runs only; the pipeline never sets it.
    [switch]$SkipNuGetCheck
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

. "$PSScriptRoot/_helpers.ps1"

$tiers = @()
if ($RunStarter    -ieq 'True') { $tiers += 'Starter' }
if ($RunStandard   -ieq 'True') { $tiers += 'Standard' }
if ($RunPro        -ieq 'True') { $tiers += 'Pro' }
if ($RunEnterprise -ieq 'True') { $tiers += 'Enterprise' }
if ($tiers.Count -eq 0) {
    Write-PipelineError "At least one tier must be selected (runStarter / runStandard / runPro / runEnterprise)."
}

switch ($Profile) {
    'smoke'    { $preset = 'Small';  $users = 20;  $spawn = 10; $duration = 60;  $engines = 1 }
    'standard' { $preset = 'Medium'; $users = 50;  $spawn = 10; $duration = 300; $engines = 1 }
    'stress'   { $preset = 'Medium'; $users = 300; $spawn = 50; $duration = 600; $engines = 2 }
    # Ramp: climb load across the whole run to find the saturation knee. Low
    # spawn (frontend/Locust ramps 0->users at 1 VU/s); JMeter ramp handled via
    # $rampTime below. Single engine so the ramp target isn't silently doubled.
    'ramp'     { $preset = 'Medium'; $users = 300; $spawn = 1;  $duration = 600; $engines = 1 }
}

# Backoffice VUs are far heavier than frontend VUs: each one holds a full
# authenticated editor session (login -> navigate tree -> save/publish), which
# is CPU-bound (auth hashing, content/cache/index work). 50 such VUs saturated
# even Standard's App CPU (~96%), so the frontend counts don't translate. Scale
# backoffice down to realistic editor concurrency and pin a single engine (ALT
# multiplies threads x engines, and these counts don't need a second engine).
# Frontend (Locust) keeps the profile defaults above. Tune these freely.
if ($Workload -eq 'backoffice') {
    $engines = 1
    switch ($Profile) {
        'smoke'    { $users = 5 }
        'standard' { $users = 15 }
        'stress'   { $users = 50 }
        # Ramp to ~60 to bracket the observed backoffice knee (~50 on Standard).
        'ramp'     { $users = 60 }
    }
}

# JMeter ramp-up window (seconds). The 'ramp' profile climbs from 0 to full
# thread count across the whole run to expose the saturation knee on the
# per-minute charts; steady profiles keep the legacy ~1-thread/sec ramp
# (ramp_time = thread count). Locust uses the low spawn rate above; this only
# drives the JMeter thread group (ThreadGroup.ramp_time = ${__P(rampTime,1)}).
$rampTime = if ($Profile -eq 'ramp') { $duration } else { $users }

# Seeder preset override (Auto keeps the profile-coupled default). Unlocks
# off-diagonal cells (Small content + stress load, Massive content + smoke
# load) and is the only way to reach the Massive preset.
if ($SeederPresetOverride -ne 'Auto') {
    $preset = $SeederPresetOverride
}

# Single source of truth shared with Terraform/modules/umbraco/scripts/install-
# umbraco-cms-on-appservice.ps1 (the actual install reads the same file).
# Loaded up front so the "supported majors" wording below is derived from it
# rather than hand-typed; the per-major gate itself runs after the cheaper
# checks. Deliberately NOT also checked against nuget.org (unlike the
# Umbraco.Templates check below) - that check was tried and pulled: see git
# history on the seeder gate if reintroducing it.
$seederVersionsPath = Join-Path $WorkspaceRoot "scripts/seeder-versions.json"
if (-not (Test-Path -LiteralPath $seederVersionsPath)) {
    Write-PipelineError "Couldn't find seeder-versions.json at '$seederVersionsPath'."
}
$seederPackageVersions = Get-Content -LiteralPath $seederVersionsPath -Raw | ConvertFrom-Json -AsHashtable
$seederShippedMajors = @($seederPackageVersions.Keys | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })

# Each Umbraco major mapped explicitly (not by range) so a future major without
# a known TFM is absent and errors, rather than silently inheriting v18/v19.
# runtime = App Service framework_version ('vX.0'), from which the UseDotNet@2
# SDK selector ('X.x') is derived. previewSdk = let UseDotNet@2 pick a pre-GA
# SDK for that selector - only for a major whose .NET hasn't GA'd yet.
# blockedBy = a reason this major can't be provisioned yet even though it's
# mapped; the run fails here with that reason instead of later in Terraform.
$runtimeMaps = @{
    13 = @{ runtime = 'v8.0';  previewSdk = $false }
    14 = @{ runtime = 'v8.0';  previewSdk = $false }
    15 = @{ runtime = 'v9.0';  previewSdk = $false }
    16 = @{ runtime = 'v9.0';  previewSdk = $false }
    17 = @{ runtime = 'v10.0'; previewSdk = $false }
    18 = @{ runtime = 'v10.0'; previewSdk = $false }   # verify against v18 release notes
    # Umbraco.Cms.* 19.0.0-beta1 targets net11.0 only (nuspec). .NET 11 was at
    # 11.0.0-rc.3 on 30-10-2026 (dotnet release index); GA is expected in
    # November 2026 per the usual .NET cadence - flip previewSdk to $false once
    # 11.0.100 is GA. blockedBy: the azurerm provider validates
    # azurerm_windows_web_app.application_stack.dotnet_version against a fixed
    # list that ends at v10.0 - in the pinned release and, as of 30-10-2026, on
    # main (internal/services/appservice/helpers/app_stack.go). Terraform/main.tf
    # constrains azurerm to '~> 4.20' while the provider's current line is 5.x,
    # so any release that adds 'v11.0' will need that constraint raised to 5.x
    # (a provider major upgrade), not just a lock bump. Remove blockedBy once
    # that's done; the rest of the v19 path is already wired.
    19 = @{ runtime = 'v11.0'; previewSdk = $true
            blockedBy = "the azurerm Terraform provider pinned in Terraform/.terraform.lock.hcl (currently {azurerm}) rejects dotnet_version 'v11.0' for a Windows App Service (see internal/services/appservice/helpers/app_stack.go in hashicorp/terraform-provider-azurerm). Any release that accepts it will be on the provider's 5.x line, which Terraform/main.tf's '~> 4.20' constraint excludes - raise that constraint (a provider major upgrade), re-init, then drop 'blockedBy' from the v19 entry in resolve-run-config.ps1" }
}
# What a queue can actually run today: mapped, not blocked, and with a seeder.
$supportedMajors = @($runtimeMaps.Keys | Where-Object { -not $runtimeMaps[$_].blockedBy -and $_ -in $seederShippedMajors } | Sort-Object)
$supportedList   = ($supportedMajors | ForEach-Object { "v$_" }) -join ', '

$umbracoMajor = Get-UmbracoMajor $UmbracoVersion
$runtimeMap = $runtimeMaps[$umbracoMajor]
$dotnetVersion = $runtimeMap.runtime
if (-not $dotnetVersion) {
    Write-PipelineError "Umbraco $UmbracoVersion is unsupported: no .NET runtime is mapped for major $umbracoMajor. This pipeline can run $supportedList today. Extend `$runtimeMaps in resolve-run-config.ps1 (and scripts/seeder-versions.json) when a new major is supported."
}
if ($runtimeMap.blockedBy) {
    # Fail here rather than at terraform plan: the provision stage only runs
    # after ensureHistoryInfra/ensureMonitoringInfra, so "plan fails" still
    # costs several minutes of agent time and idempotent-infra churn per attempt.
    # The pinned provider version is read from the lock file so the message
    # can't go stale on a lock bump.
    $azurermPinned = 'unknown'
    $lockPath = Join-Path $WorkspaceRoot 'Terraform/.terraform.lock.hcl'
    if (Test-Path -LiteralPath $lockPath) {
        $lock = Get-Content -LiteralPath $lockPath -Raw
        if ($lock -match 'provider "registry\.terraform\.io/hashicorp/azurerm" \{\s*version\s*=\s*"([^"]+)"') { $azurermPinned = $Matches[1] }
    }
    $reason = $runtimeMap.blockedBy.Replace('{azurerm}', $azurermPinned)
    Write-PipelineError "Umbraco $UmbracoVersion (major $umbracoMajor, .NET $dotnetVersion) can't be provisioned yet: $reason. Runnable today: $supportedList."
}
$sdkVersion = $dotnetVersion -replace '^v(\d+)\.0$', '$1.x'
$sdkIncludePreview = if ($runtimeMap.previewSdk) { 'true' } else { 'false' }

# Confirm the exact requested version is actually published before Terraform
# provisions anything. install-umbraco-cms-on-appservice.ps1's first package
# pull is `dotnet new install "Umbraco.Templates@$UmbracoVersion"`, so that's
# the most direct proxy for "will this install structurally succeed" - a typo'd
# or not-yet-published version (a queued RC that hasn't hit any feed yet) would
# otherwise fail 10+ minutes into deploy_umbraco, after a full App Service + SQL
# DB were already stood up. Same "fail here costs nothing" rationale as below.
# Checked against every feed the install restores from, so nightly tags pass.
if (-not $SkipNuGetCheck) {
    if (-not (Test-NuGetPackageVersionExists -PackageId 'Umbraco.Templates' -Version $UmbracoVersion)) {
        Write-PipelineError "Umbraco.Templates $UmbracoVersion was not found on nuget.org or the Umbraco prerelease/nightly MyGet feeds (checked $($UmbracoPackageFlatContainerUrls -join ', '); a feed warned about as unreachable above was skipped). Verify the version string and that it's actually published before queuing - this pipeline provisions a full App Service + SQL DB before install-umbraco-cms-on-appservice.ps1 would otherwise discover this."
    }
}

# Validate that the chosen (scenario, workload) pair has the files the runner
# will look for. Failing here costs nothing; failing 15 minutes into the
# provision stage when generate-loadtest-config can't find a .jmx wastes
# real Azure time and money.
$scenarioRoot = Join-Path $WorkspaceRoot "loadtests/scenarios/$Scenario"
if (-not (Test-Path -LiteralPath $scenarioRoot -PathType Container)) {
    Write-PipelineError "Scenario '$Scenario' has no folder under loadtests/scenarios/. Available scenarios are the subfolders of loadtests/scenarios/."
}
if ($Workload -eq 'frontend') {
    $locustfilePath = Join-Path $scenarioRoot 'locustfile.py'
    if (-not (Test-Path -LiteralPath $locustfilePath)) {
        Write-PipelineError "Workload=frontend selected but scenario '$Scenario' has no locustfile.py. Either add one or pick a different workload."
    }
} elseif ($Workload -eq 'backoffice') {
    $jmeterMajor = Get-JmeterMajor $umbracoMajor
    $jmeterDir = Join-Path $scenarioRoot "jmeter/v$jmeterMajor"
    if (-not (Test-Path -LiteralPath $jmeterDir -PathType Container)) {
        Write-PipelineError "Workload=backoffice selected but scenario '$Scenario' has no jmeter/v$jmeterMajor/ folder (looked at $jmeterDir). Add JMeter test plans there or pick a different scenario."
    }
    $jmxFiles = @(Get-ChildItem -Path $jmeterDir -Filter '*.jmx' -File -ErrorAction SilentlyContinue)
    if ($jmxFiles.Count -eq 0) {
        Write-PipelineError "Workload=backoffice selected but $jmeterDir contains no .jmx files."
    }
} elseif ($Workload -eq 'client') {
    # Client workload = the scenario's Playwright project. Fail at queue-time if
    # absent, mirroring the frontend/backoffice checks above.
    $clientConfig = Join-Path $scenarioRoot 'client/playwright.config.ts'
    if (-not (Test-Path -LiteralPath $clientConfig)) {
        Write-PipelineError "Workload=client selected but scenario '$Scenario' has no client/ project (looked for $clientConfig). Add a Playwright project under loadtests/scenarios/$Scenario/client/ or pick a different workload."
    }
}

# Seeder gate (map loaded at the top of this script). Checked here so a major
# without a published seeder build fails at validation (minute 0) instead of
# install (minute ~10), after Terraform has already stood up a full App Service
# + SQL DB.
$seederPackageVersion = $seederPackageVersions["$umbracoMajor"]
if (-not $seederPackageVersion) {
    Write-PipelineError "Umbraco.Cms.TestDataSeeder hasn't shipped a build for major $umbracoMajor yet (no entry in scripts/seeder-versions.json). Update scripts/seeder-versions.json once the package ships for that major."
}

# 'Auto' = Terraform's "use the tier's default" sentinel (0 for DTU, '' for SKU).
$poolDtuOverrideValue = if ($PoolDtuOverride -eq 'Auto') { '0' } else { $PoolDtuOverride }
$appSkuOverrideValue  = if ($AppSkuOverride  -eq 'Auto') { ''  } else { $AppSkuOverride  }

Write-Host "Tiers:           $($tiers -join ', ')"
Write-Host "Profile '$Profile': preset=$preset users=$users spawn=$spawn duration=${duration}s engines=$engines"
Write-Host "Umbraco $UmbracoVersion (major $umbracoMajor) -> .NET $dotnetVersion (SDK $sdkVersion, preview SDKs: $sdkIncludePreview)"
Write-Host "Pool DTU override: $(if ($poolDtuOverrideValue -ne '0') { "$poolDtuOverrideValue DTUs per DB" } else { 'Auto (per-tier defaults)' })"
Write-Host "App SKU override:  $(if ($appSkuOverrideValue) { $appSkuOverrideValue } else { 'Auto (per-tier defaults)' })"

$testCases = @(@{
    umbraco  = $UmbracoVersion
    dotnet   = $dotnetVersion
    scenario = $Scenario
    tiers    = $tiers
})
$env:TEST_CASES_JSON = ($testCases | ConvertTo-Json -Compress -Depth 5)

# Downstream stages read these via $[stageDependencies.X.Y.outputs['out.NAME']].
Write-Host "##vso[task.setvariable variable=resolvedDotnetVersion;isOutput=true]$dotnetVersion"
Write-Host "##vso[task.setvariable variable=resolvedSdkVersion;isOutput=true]$sdkVersion"
Write-Host "##vso[task.setvariable variable=resolvedSdkIncludePreview;isOutput=true]$sdkIncludePreview"
Write-Host "##vso[task.setvariable variable=resolvedSeederPreset;isOutput=true]$preset"
Write-Host "##vso[task.setvariable variable=resolvedEngineInstances;isOutput=true]$engines"
Write-Host "##vso[task.setvariable variable=resolvedPoolDtuOverride;isOutput=true]$poolDtuOverrideValue"
Write-Host "##vso[task.setvariable variable=resolvedAppSkuOverride;isOutput=true]$appSkuOverrideValue"
Write-Host "##vso[task.setvariable variable=resolvedWorkload;isOutput=true]$Workload"

# prepare-test-cases.ps1 expands one entry × N tiers into N test cases and
# emits the final testCasesJson + resolvedTestCases output variables.
& "$WorkspaceRoot/scripts/prepare-test-cases.ps1" `
    -UserAmount $users `
    -SpawnRate $spawn `
    -TestDuration $duration `
    -RampTime $rampTime `
    -LoadProfile $Profile `
    -WorkspaceRoot $WorkspaceRoot
