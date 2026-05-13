# Generate the Azure Load Testing config YAML for one test case.
#
# Writes the config to $OutputDir/loadtest-config-<safeTestCaseId>.yaml and emits
# three pipeline variables: safeTestCaseId, loadTestConfigPath, appServiceResourceId.
# Sanitises the scenario and testCaseId into ALT-compatible names (lowercase
# alphanumeric + hyphens, ≤50 chars).
#
# testId is shared across all cases of one scenario so the portal's 'Compare runs'
# view nests every (version × tier) run under a single test, letting reviewers
# overlay them.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$AppServiceName,
    [Parameter(Mandatory = $true)] [string]$ResourceGroupName,
    [Parameter(Mandatory = $true)] [string]$HostName,
    [Parameter(Mandatory = $true)] [string]$Scenario,
    [Parameter(Mandatory = $true)] [string]$TestCaseId,
    [Parameter(Mandatory = $true)] [int]$EngineInstances,
    [Parameter(Mandatory = $true)] [int]$UserAmount,
    [Parameter(Mandatory = $true)] [int]$SpawnRate,
    [Parameter(Mandatory = $true)] [int]$TestDuration,

    # Optional resource IDs — App Service Plan + SQL Database — used to register
    # extra appComponents in ALT so plan-level (CpuPercentage / MemoryPercentage)
    # and database-level (DTU / log writes / etc.) metrics are captured alongside
    # site-level metrics during the run.
    [string]$AppServicePlanId,
    [string]$SqlDatabaseId,
    [string]$SqlDatabaseName,

    [string]$OutputDir = $PWD
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

$subscriptionId = az account show --query id -o tsv
$appServiceResourceId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$AppServiceName"

# CpuPercentage / MemoryPercentage live on the App Service Plan
# (Microsoft.Web/serverfarms), not the site — register the plan as its own
# appComponent. SQL metrics scope to the database, not the server.
$planComponent = ""
if ($AppServicePlanId) {
$planComponent = @"
  - resourceId: "$AppServicePlanId"
    resourceName: "$AppServiceName-plan"
    kind: "app"
    metrics:
      - name: CpuPercentage
        namespace: Microsoft.Web/serverfarms
        aggregation: Average
      - name: MemoryPercentage
        namespace: Microsoft.Web/serverfarms
        aggregation: Average
"@
}

$sqlComponent = ""
if ($SqlDatabaseId) {
$sqlComponent = @"
  - resourceId: "$SqlDatabaseId"
    resourceName: "$SqlDatabaseName"
    kind: "v12.0"
    metrics:
      - name: dtu_consumption_percent
        namespace: Microsoft.Sql/servers/databases
        aggregation: Average
      - name: cpu_percent
        namespace: Microsoft.Sql/servers/databases
        aggregation: Average
      - name: physical_data_read_percent
        namespace: Microsoft.Sql/servers/databases
        aggregation: Average
      - name: log_write_percent
        namespace: Microsoft.Sql/servers/databases
        aggregation: Average
      - name: connection_successful
        namespace: Microsoft.Sql/servers/databases
        aggregation: Total
      - name: deadlock
        namespace: Microsoft.Sql/servers/databases
        aggregation: Total
"@
}

# testId must match ^[a-z0-9_-]{2,50}$. One testId per scenario so the portal's
# 'Compare runs' view groups all (version × tier) runs of the same scenario.
$scenarioSafe = (($Scenario.ToLowerInvariant() -replace '[^a-z0-9]', '-') -replace '-+', '-').Trim('-')
$testId = "umbraco-lt-$scenarioSafe"

# safeTestCaseId identifies this specific case for the artifact name + config filename.
$safeKey = (($TestCaseId.ToLowerInvariant() -replace '[^a-z0-9]', '-') -replace '-+', '-').Trim('-')
if ($safeKey.Length -gt 50) { $safeKey = $safeKey.Substring(0, 50) }

$config = @"
version: v0.1
testId: $testId
displayName: Umbraco load test - $Scenario
testPlan: loadtests/scenarios/$Scenario/locustfile.py
testType: Locust
description: Holds all version/tier runs for the '$Scenario' scenario; pick runs in 'Compare' to overlay.
engineInstances: $EngineInstances
configurationFiles:
  - loadtests/locust.conf
  - loadtests/_helpers.py
failureCriteria:
  - avg(response_time_ms) > 2000
  - p95(response_time_ms) > 5000
  - percentage(error) > 5
autoStop:
  errorPercentage: 80
  timeWindow: 60
env:
  - name: LOCUST_HOST
    value: "https://$HostName"
  - name: LOCUST_USERS
    value: "$UserAmount"
  - name: LOCUST_SPAWN_RATE
    value: "$SpawnRate"
  - name: LOCUST_RUN_TIME
    value: "$TestDuration"
appComponents:
  - resourceId: "$appServiceResourceId"
    resourceName: "$AppServiceName"
    kind: "app"
    metrics:
      - name: HttpResponseTime
        namespace: Microsoft.Web/sites
        aggregation: Average
      - name: Requests
        namespace: Microsoft.Web/sites
        aggregation: Total
      - name: Http5xx
        namespace: Microsoft.Web/sites
        aggregation: Total
      - name: Http4xx
        namespace: Microsoft.Web/sites
        aggregation: Total
$planComponent
$sqlComponent
"@

$configPath = Join-Path $OutputDir "loadtest-config-$safeKey.yaml"
$config | Out-File -FilePath $configPath -Encoding utf8

# Pipeline-variable emissions consumed by downstream tasks in load-test-job.yml.
Write-Host "##vso[task.setvariable variable=safeTestCaseId]$safeKey"
Write-Host "##vso[task.setvariable variable=loadTestConfigPath]$configPath"
Write-Host "##vso[task.setvariable variable=appServiceResourceId]$appServiceResourceId"

Write-Host "Generated load test config at: $configPath"
Write-Host "App Service:      $appServiceResourceId"
if ($AppServicePlanId) { Write-Host "App Service Plan: $AppServicePlanId" }
if ($SqlDatabaseId)    { Write-Host "SQL Database:     $SqlDatabaseId" }
