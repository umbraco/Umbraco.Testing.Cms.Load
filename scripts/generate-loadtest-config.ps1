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

    # Resource IDs — App Service Plan + SQL Database — used to register extra
    # appComponents in ALT so plan-level (CpuPercentage / MemoryPercentage) and
    # database-level (DTU / log writes / etc.) metrics are captured alongside
    # site-level metrics during the run.
    [Parameter(Mandatory = $true)] [string]$AppServicePlanId,
    [Parameter(Mandatory = $true)] [string]$SqlDatabaseId,
    [Parameter(Mandatory = $true)] [string]$SqlDatabaseName,

    # Workload selector: 'frontend' (Locust) or 'backoffice' (JMeter). For
    # backoffice mode, UmbracoVersion is required to pick the right .jmx
    # subfolder (v17 .jmx files are also used for v18 — matches the seeder
    # fallback in install-umbraco-cms-on-appservice.ps1).
    [ValidateSet('frontend', 'backoffice')] [string]$Workload = 'frontend',
    [string]$UmbracoVersion = '',

    [string]$OutputDir = $PWD
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

$subscriptionId = az account show --query id -o tsv
$appServiceResourceId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$AppServiceName"

# CpuPercentage / MemoryPercentage live on the App Service Plan
# (Microsoft.Web/serverfarms), not the site — register the plan as its own
# appComponent. SQL metrics scope to the database, not the server.
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

# testId must match ^[a-z0-9_-]{2,50}$. The workload suffix keeps frontend and
# backoffice runs in separate testIds so ALT's 'Compare runs' view doesn't
# overlay fundamentally different traffic shapes.
$scenarioSafe = (($Scenario.ToLowerInvariant() -replace '[^a-z0-9]', '-') -replace '-+', '-').Trim('-')
$workloadSuffix = if ($Workload -eq 'backoffice') { '-backoffice' } else { '' }
$testId = "umbraco-lt-$scenarioSafe$workloadSuffix"

# safeTestCaseId identifies this specific case for the artifact name + config filename.
$safeKey = (($TestCaseId.ToLowerInvariant() -replace '[^a-z0-9]', '-') -replace '-+', '-').Trim('-')
if ($safeKey.Length -gt 50) { $safeKey = $safeKey.Substring(0, 50) }

# Shared ALT failure criteria + autoStop + appComponents — applied regardless
# of runner so cross-workload runs stay comparable on those axes.
$sharedTail = @"
failureCriteria:
  - avg(response_time_ms) > 2000
  - p95(response_time_ms) > 5000
  - percentage(error) > 5
autoStop:
  errorPercentage: 80
  timeWindow: 60
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

if ($Workload -eq 'backoffice') {
    # JMeter mode. v17 .jmx files are used for v18 deployments — matches the
    # seeder fallback in install-umbraco-cms-on-appservice.ps1.
    if (-not $UmbracoVersion) {
        Write-Error "Workload=backoffice requires -UmbracoVersion to pick the .jmx subfolder."
        exit 1
    }
    $umbracoMajor = [int](($UmbracoVersion -split '\.')[0])
    $jmeterMajor  = if ($umbracoMajor -eq 18) { 17 } else { $umbracoMajor }
    $jmeterDir    = "loadtests/scenarios/$Scenario/jmeter/v$jmeterMajor"

    # PoC: run ONE .jmx (ViewHomePage — frontend GET, no auth needed).
    # Multi-.jmx looping comes after this validates end-to-end.
    $testPlanRel = "$jmeterDir/ViewHomePage.jmx"
    $testPlanAbs = Join-Path $PWD $testPlanRel
    if (-not (Test-Path -LiteralPath $testPlanAbs)) {
        Write-Error "JMeter test plan not found: $testPlanAbs (resolved jmeter major: v$jmeterMajor)"
        exit 1
    }

    # ALT passes per-run values via a user-properties file. Sibling to the
    # YAML so ALT uploads both. The .jmx files reference each property via
    # \${__P(name,default)} — see scripts/parameterize-jmx.js.
    $propsFileName = "jmeter-$safeKey.properties"
    $propsPath = Join-Path $OutputDir $propsFileName
    $propsBody = @"
server=$HostName
protocol=https
port=443
numberOfThread=$UserAmount
duration=$TestDuration
backoffice_username=admin@umbraco
backoffice_password=1234567890
"@
    $propsBody | Out-File -FilePath $propsPath -Encoding utf8

    $config = @"
version: v0.1
testId: $testId
displayName: Umbraco load test - $Scenario (backoffice)
testPlan: $testPlanRel
testType: JMX
description: Backoffice (JMeter) runs for the '$Scenario' scenario.
engineInstances: $EngineInstances
configurationFiles: []
properties:
  userPropertyFile: $propsFileName
$sharedTail
"@
} else {
    # Frontend (Locust) mode — unchanged from prior behaviour.
    $config = @"
version: v0.1
testId: $testId
displayName: Umbraco load test - $Scenario
testPlan: loadtests/scenarios/$Scenario/locustfile.py
testType: Locust
description: Holds all version/tier runs for the '$Scenario' scenario; pick runs in 'Compare' to overlay.
engineInstances: $EngineInstances
configurationFiles:
  - loadtests/_helpers.py
env:
  - name: LOCUST_HOST
    value: "https://$HostName"
  - name: LOCUST_USERS
    value: "$UserAmount"
  - name: LOCUST_SPAWN_RATE
    value: "$SpawnRate"
  - name: LOCUST_RUN_TIME
    value: "$TestDuration"
$sharedTail
"@
}

$configPath = Join-Path $OutputDir "loadtest-config-$safeKey.yaml"
$config | Out-File -FilePath $configPath -Encoding utf8

# Pipeline-variable emissions consumed by downstream tasks in load-test-job.yml.
Write-Host "##vso[task.setvariable variable=safeTestCaseId]$safeKey"
Write-Host "##vso[task.setvariable variable=loadTestConfigPath]$configPath"
Write-Host "##vso[task.setvariable variable=appServiceResourceId]$appServiceResourceId"

Write-Host "Generated load test config at: $configPath"
Write-Host "App Service:      $appServiceResourceId"
Write-Host "App Service Plan: $AppServicePlanId"
Write-Host "SQL Database:     $SqlDatabaseId"
