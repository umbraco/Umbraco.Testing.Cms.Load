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
    [Parameter(Mandatory = $true)] [ValidateSet('smoke', 'standard', 'stress')] [string]$Profile,
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
    [Parameter(Mandatory = $true)] [ValidateSet('frontend', 'backoffice')] [string]$Workload,
    [Parameter(Mandatory = $true)] [string]$WorkspaceRoot
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
    'stress'   { $preset = 'Large';  $users = 300; $spawn = 50; $duration = 600; $engines = 2 }
}

# Seeder preset override (Auto keeps the profile-coupled default). Unlocks
# off-diagonal cells (Small content + stress load, Massive content + smoke
# load) and is the only way to reach the Massive preset.
if ($SeederPresetOverride -ne 'Auto') {
    $preset = $SeederPresetOverride
}

# Each Umbraco major mapped explicitly (not by range) so a future major without
# a known TFM hits default and errors, rather than silently inheriting v17/v18.
# dotnetVersion = App Service framework_version ('vX.0'); sdkVersion = SDK feed
# selector for UseDotNet@2 ('X.x').
$umbracoMajor = Get-UmbracoMajor $UmbracoVersion
$dotnetVersion = switch ($umbracoMajor) {
    13      { 'v8.0' }
    14      { 'v8.0' }
    15      { 'v9.0' }
    16      { 'v9.0' }
    17      { 'v10.0' }
    18      { 'v10.0' }   # verify against v18 release notes
    default { $null }
}
if (-not $dotnetVersion) {
    # Note the runnable set is narrower than this TFM map: the seeder gate below
    # blocks 14/15/16. The honest "what can actually run" answer is v13, v17, v18.
    Write-PipelineError "Umbraco $UmbracoVersion is unsupported. This pipeline supports v13, v17, and v18 (the majors with a published TestDataSeeder build; v18 reuses v17's). Extend the major→runtime map in resolve-run-config.ps1 when a new major is supported."
}
$sdkVersion = $dotnetVersion -replace '^v(\d+)\.0$', '$1.x'

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
    # Mirror the v17→v18 fallback used in generate-loadtest-config.ps1 and the
    # seeder package map in install-umbraco-cms-on-appservice.ps1.
    $jmeterMajor = if ($umbracoMajor -eq 18) { 17 } else { $umbracoMajor }
    $jmeterDir = Join-Path $scenarioRoot "jmeter/v$jmeterMajor"
    if (-not (Test-Path -LiteralPath $jmeterDir -PathType Container)) {
        Write-PipelineError "Workload=backoffice selected but scenario '$Scenario' has no jmeter/v$jmeterMajor/ folder (looked at $jmeterDir). Add JMeter test plans there or pick a different scenario."
    }
    $jmxFiles = @(Get-ChildItem -Path $jmeterDir -Filter '*.jmx' -File -ErrorAction SilentlyContinue)
    if ($jmxFiles.Count -eq 0) {
        Write-PipelineError "Workload=backoffice selected but $jmeterDir contains no .jmx files."
    }
}

# Mirror of $seederPackageVersions in
# Terraform/modules/umbraco/scripts/install-umbraco-cms-on-appservice.ps1.
# Listed here so a major without a published seeder build fails at validation
# (minute 0) instead of install (minute ~10). Update both sites in lockstep
# when a new seeder ships. v18 isn't listed directly because it uses the v17
# seeder as a fallback (see the install script); add 18 once a dedicated v18
# build ships.
$seederShippedMajors = @(13, 17, 18)
if ($seederShippedMajors -notcontains $umbracoMajor) {
    Write-PipelineError "Umbraco.Cms.TestDataSeeder hasn't shipped a build for major $umbracoMajor yet. Currently shipped: v13 (beta), v17, v18 (via v17 fallback). Update the maps in resolve-run-config.ps1 + Terraform/modules/umbraco/scripts/install-umbraco-cms-on-appservice.ps1 once the package ships."
}

# 'Auto' = Terraform's "use the tier's default" sentinel (0 for DTU, '' for SKU).
$poolDtuOverrideValue = if ($PoolDtuOverride -eq 'Auto') { '0' } else { $PoolDtuOverride }
$appSkuOverrideValue  = if ($AppSkuOverride  -eq 'Auto') { ''  } else { $AppSkuOverride  }

Write-Host "Tiers:           $($tiers -join ', ')"
Write-Host "Profile '$Profile': preset=$preset users=$users spawn=$spawn duration=${duration}s engines=$engines"
Write-Host "Umbraco $UmbracoVersion (major $umbracoMajor) -> .NET $dotnetVersion"
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
    -WorkspaceRoot $WorkspaceRoot
