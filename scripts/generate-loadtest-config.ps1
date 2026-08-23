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
    # JMeter thread-group ramp-up (seconds). 0 = fall back to UserAmount (legacy
    # ~1-thread/sec ramp); the 'ramp' profile passes the full duration so load
    # climbs across the whole run.
    [int]$RampTime = 0,

    # Load profile name — the authoritative ramp signal. A ramp run relaxes the
    # absolute failure criteria (it deliberately drives into saturation, so
    # latency/error gates would FAIL/autoStop at the knee). Keyed on the profile
    # rather than RampTime or SpawnRate, both of which scenario.yaml can override.
    [string]$LoadProfile = '',

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

    # Backoffice-only: seeder state discovered by the "Discover seeder member
    # state" step in load-test-job.yml (queries the SUT's
    # /umbraco/api/seederstatus/inventory?includeMemberPassword=true). These
    # flow into the .properties file as totalOfMember + member_password so
    # MemberLogin.jmx's Groovy preprocessor picks a real seeded member rather
    # than a hardcoded count of 30 that may not exist when the seeder uses
    # Small (10 members) or Custom presets.
    # The seeded prefix isn't taken as a parameter — the .jmx Groovy hardcodes
    # 'TestMember_' (matching the seeder default), so passing a discovered
    # prefix through would be dead plumbing until the .jmx is updated to read
    # the prefix from a property as well.
    # Optional with safe defaults — frontend mode never sets these.
    [int]$SeededMemberCount = 30,
    [string]$SeededMemberPassword = 'Test1234!',

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

# The backoffice loop in load-test-job.yml invokes this script once per .jmx
# (up to 6x per case), each as a fresh process - cache the subscription ID
# (constant for the whole pipeline run) in a file next to the generated
# configs instead of paying the `az account show` round-trip on every call.
$subIdCachePath = Join-Path $OutputDir ".subscription-id-cache"
if (Test-Path -LiteralPath $subIdCachePath) {
    $subscriptionId = (Get-Content -LiteralPath $subIdCachePath -Raw).Trim()
} else {
    $subscriptionId = az account show --query id -o tsv
    $subscriptionId | Out-File -FilePath $subIdCachePath -Encoding utf8 -NoNewline
}
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

# ALT enforces a SEPARATE 50-char limit on displayName (config YAML key).
# Previously this was "Umbraco load test - {Scenario} / {JmxName}" which
# overflowed for the longest .jmx ('SaveAndPublishContent' = 21 chars):
# "Umbraco load test - Default / SaveAndPublishContent" = 51 chars → ALT
# rejected the YAML and the whole iteration died (Bug A from the
# first end-to-end run). Drop the redundant prefix — the test list is
# already inside an ALT resource named "umbraco-loadtest-runs", so the
# "Umbraco load test" preamble was just noise.
$displayName = if ($Workload -eq 'backoffice') { "$Scenario / $JmxName" } else { "$Scenario" }
if ($displayName.Length -gt 50) {
    Write-Error "Computed ALT displayName '$displayName' is $($displayName.Length) chars; ALT max is 50. Shorten scenario or .jmx stem."
    exit 1
}

# safeTestCaseId identifies this specific case for the artifact name + config filename.
# For backoffice runs we append the .jmx stem so each .jmx in a single pipeline
# run lands on a unique artifact name + config file (otherwise iteration N would
# overwrite iteration N-1's outputs in the same agent workspace).
$safeKey = (($TestCaseId.ToLowerInvariant() -replace '[^a-z0-9]', '-') -replace '-+', '-').Trim('-')
if ($JmxName) { $safeKey = "$safeKey-$jmxSafe" }
if ($safeKey.Length -gt 50) { $safeKey = $safeKey.Substring(0, 50) }

# Effective ramp-up + whether this is a ramp run. Keyed on the profile name — the
# only ramp signal scenario.yaml can't override (it can override users/spawn/
# duration, so RampTime>=duration and SpawnRate==1 are both unreliable).
$rampTimeEff = if ($RampTime -gt 0) { $RampTime } else { $UserAmount }
$isRamp      = ($LoadProfile -eq 'ramp')

# Failure criteria + autoStop. A ramp run is *designed* to climb into saturation
# to find the knee, so the absolute latency gates (and a low autoStop) would FAIL
# or cancel it the moment it gets there — defeating the point. For ramp, drop the
# latency criteria, keep only a high error ceiling, and raise autoStop so the run
# completes and the per-minute charts show the full climb.
if ($isRamp) {
    $criteriaBlock = @"
failureCriteria:
  - percentage(error) > 90
autoStop:
  errorPercentage: 95
  timeWindow: 120
"@
} else {
    $criteriaBlock = @"
failureCriteria:
  - avg(response_time_ms) > 2000
  - p95(response_time_ms) > 5000
  - percentage(error) > 5
autoStop:
  errorPercentage: 80
  timeWindow: 60
"@
}

# Shared ALT failure criteria + autoStop + appComponents — applied regardless
# of runner so cross-workload runs stay comparable on those axes.
$sharedTail = @"
$criteriaBlock
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
    # Two credential pairs are written because the .jmx files split cleanly:
    #
    #   - MemberLogin.jmx uses a Groovy preprocessor to construct
    #     `member_username = "TestMember_<random 1..totalOfMember>"` per
    #     iteration. We provide totalOfMember + member_password from the
    #     seeder inventory (queried by load-test-job.yml's "Discover seeder
    #     member state" step), so they track whatever the seeder actually
    #     created. The Groovy still hardcodes "TestMember_" — if the seeder
    #     prefix is ever customized away from the default, the Groovy needs
    #     to read a memberPrefix variable too. (Not done yet — the seeder
    #     default IS "TestMember_" and we don't customize it.)
    #
    #   - SaveContent / SaveAndPublishContent / SaveDocumentType / PublishContent
    #     authenticate against the backoffice management API. The seeder's
    #     TestUser_* accounts have no password (UserSeeder.cs never sets one),
    #     so the only usable account is the Terraform unattended-install admin
    #     (loadtest@example.invalid / LoadTest123! from
    #     Terraform/modules/umbraco/versions/main.tf).
    #
    # If the discovery step fell back to defaults (seeder endpoint unreachable),
    # these values are still the safe defaults a fresh seeder uses, so the loop
    # can still attempt to run — MemberLogin may have a degraded hit rate.
    $propsFileName = "jmeter-$safeKey.properties"
    $propsPath = Join-Path $OutputDir $propsFileName
    $propsBody = @"
server=$HostName
protocol=https
port=443
numberOfThread=$UserAmount
duration=$TestDuration
rampTime=$rampTimeEff
totalOfMember=$SeededMemberCount
member_password=$SeededMemberPassword
backoffice_username=loadtest@example.invalid
backoffice_password=LoadTest123!
"@
    $propsBody | Out-File -FilePath $propsPath -Encoding utf8

    $config = @"
version: v0.1
testId: $testId
displayName: $displayName
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
displayName: $displayName
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
