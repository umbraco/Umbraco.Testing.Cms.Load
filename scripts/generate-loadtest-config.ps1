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

    # Backoffice-only: the .jmx file stem to run (e.g. 'ViewHomePage',
    # 'SaveContent'). Each .jmx is its own ALT test with its own testId, so
    # runs of different .jmx files don't overlay in the portal's Compare view.
    # The template at load-test-job.yml iterates the full set; this script
    # exits 0 (with an empty loadTestConfigPath variable) when the requested
    # .jmx isn't present for the resolved major — used to skip e.g.
    # PublishContent.jmx on v13 where it doesn't exist.
    [string]$JmxName = '',

    [string]$OutputDir = $PWD
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

# Clear every pipeline variable this script emits BEFORE any logic that could
# fail. The backoffice loop in load-test-job.yml runs this script per .jmx, and
# downstream steps gate on `ne(loadTestConfigPath, '')` to skip skipped/failed
# iterations. If an exception fires here before the success-path emissions, the
# variables would otherwise retain the PREVIOUS iteration's values — and the
# current iteration's ALT step would re-run the previous .jmx with the current
# iteration's metadata. Silent data corruption. Clearing upfront makes failure
# paths fail closed.
Write-Host "##vso[task.setvariable variable=safeTestCaseId]"
Write-Host "##vso[task.setvariable variable=loadTestConfigPath]"
Write-Host "##vso[task.setvariable variable=appServiceResourceId]"
Write-Host "##vso[task.setvariable variable=jmeterTestName]"

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

# testId must match ^[a-z0-9_-]{2,50}$. Each .jmx file is its own ALT test
# (different test plans aren't meaningfully comparable across the Compare view),
# so backoffice mode appends a per-.jmx suffix. Backoffice marker shortened
# from -backoffice- to -bo- so even the longest .jmx stem
# ('saveandpublishcontent', 21 chars) plus scenario fits within 50 chars.
$scenarioSafe = (($Scenario.ToLowerInvariant() -replace '[^a-z0-9]', '-') -replace '-+', '-').Trim('-')
$jmxSafe = if ($JmxName) { ($JmxName.ToLowerInvariant() -replace '[^a-z0-9]', '-') -replace '-+', '-' } else { '' }
$workloadSuffix = if ($Workload -eq 'backoffice') { "-bo-$jmxSafe" } else { '' }
$testId = "umbraco-lt-$scenarioSafe$workloadSuffix"
if ($testId.Length -gt 50) {
    Write-Error "Computed ALT testId '$testId' is $($testId.Length) chars; ALT max is 50. Shorten scenario or .jmx stem."
    exit 1
}

# safeTestCaseId identifies this specific case for the artifact name + config filename.
# For backoffice runs we append the .jmx stem so each .jmx in a single pipeline
# run lands on a unique artifact name + config file (otherwise iteration N would
# overwrite iteration N-1's outputs in the same agent workspace).
$safeKey = (($TestCaseId.ToLowerInvariant() -replace '[^a-z0-9]', '-') -replace '-+', '-').Trim('-')
if ($JmxName) { $safeKey = "$safeKey-$jmxSafe" }
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
    if (-not $JmxName) {
        Write-Error "Workload=backoffice requires -JmxName (e.g. 'ViewHomePage') to pick the .jmx file."
        exit 1
    }
    $umbracoMajor = [int](($UmbracoVersion -split '\.')[0])
    $jmeterMajor  = if ($umbracoMajor -eq 18) { 17 } else { $umbracoMajor }
    $jmeterDir    = "loadtests/scenarios/$Scenario/jmeter/v$jmeterMajor"

    $testPlanRel = "$jmeterDir/$JmxName.jmx"
    $testPlanAbs = Join-Path $PWD $testPlanRel
    if (-not (Test-Path -LiteralPath $testPlanAbs)) {
        # Not a fatal condition — the template iterates the full .jmx name set,
        # and not every .jmx exists in every major (e.g. PublishContent.jmx is
        # v17+ only). Emit empty config-path vars so downstream steps skip this
        # iteration via their ne(loadTestConfigPath, '') condition.
        Write-Host "JMeter test plan not present: $testPlanRel (jmeter major: v$jmeterMajor) - skipping this .jmx for this run."
        Write-Host "##vso[task.setvariable variable=safeTestCaseId]"
        Write-Host "##vso[task.setvariable variable=loadTestConfigPath]"
        Write-Host "##vso[task.setvariable variable=appServiceResourceId]"
        Write-Host "##vso[task.setvariable variable=jmeterTestName]"
        exit 0
    }

    # ALT passes per-run values via a user-properties file. Sibling to the
    # YAML so ALT uploads both. The .jmx files reference each property via
    # \${__P(name,default)} — see scripts/parameterize-jmx.js.
    #
    # backoffice_username/_password match the defaults baked into every .jmx
    # file (e.g. ${__P(backoffice_username,hnd@acceptance.test)}). The .jmx
    # files use this single variable for BOTH front-end member login (e.g.
    # MemberLogin.jmx POSTs to /umbraco/api/memberlogin/login) and backoffice
    # admin login (e.g. SaveContent.jmx hits /umbraco/management/api/v1/...),
    # which implies the original authors expected one seeded fixture user with
    # both roles. Whether Umbraco.Cms.TestDataSeeder actually creates a user
    # named 'hnd@acceptance.test' / '0123456789' is unverified — if MemberLogin
    # and SaveContent show 100% errors in the first end-to-end run, the seeder
    # likely creates a different fixture user and this needs updating.
    #
    # The Terraform unattended-install admin ('loadtest@example.invalid' /
    # 'LoadTest123!' from Terraform/modules/umbraco/versions/main.tf) is a
    # SEPARATE user and is NOT what the .jmx files expect.
    $propsFileName = "jmeter-$safeKey.properties"
    $propsPath = Join-Path $OutputDir $propsFileName
    $propsBody = @"
server=$HostName
protocol=https
port=443
numberOfThread=$UserAmount
duration=$TestDuration
backoffice_username=hnd@acceptance.test
backoffice_password=0123456789
"@
    $propsBody | Out-File -FilePath $propsPath -Encoding utf8

    $config = @"
version: v0.1
testId: $testId
displayName: Umbraco load test - $Scenario / $JmxName
testPlan: $testPlanRel
testType: JMX
description: Backoffice JMeter run ($JmxName) for the '$Scenario' scenario.
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
# jmeterTestName is the .jmx stem (empty for Locust runs); the publish step
# uses it to differentiate blob paths and tag LA rows when backoffice mode
# emits multiple results per (version × tier).
Write-Host "##vso[task.setvariable variable=safeTestCaseId]$safeKey"
Write-Host "##vso[task.setvariable variable=loadTestConfigPath]$configPath"
Write-Host "##vso[task.setvariable variable=appServiceResourceId]$appServiceResourceId"
Write-Host "##vso[task.setvariable variable=jmeterTestName]$JmxName"

Write-Host "Generated load test config at: $configPath"
Write-Host "App Service:      $appServiceResourceId"
Write-Host "App Service Plan: $AppServicePlanId"
Write-Host "SQL Database:     $SqlDatabaseId"
