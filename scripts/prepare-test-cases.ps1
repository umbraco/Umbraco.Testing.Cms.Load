#requires -Version 7.3

# Validate the testCases JSON (built by the pipeline from the queue-time params or
# supplied via -TestCasesJson / TEST_CASES_JSON env var), expand the tiers axis,
# flatten scenario appsettings, resolve load profiles, emit two output variables
# for downstream stages.

[CmdletBinding()]
param (
    # Prefer env var over -TestCasesJson; AzDO's convertToJson() may emit chars unsafe for arg quoting.
    [string] $TestCasesJson = $env:TEST_CASES_JSON,
    [Parameter(Mandatory = $true)] [int]    $UserAmount,
    [Parameter(Mandatory = $true)] [int]    $SpawnRate,
    [Parameter(Mandatory = $true)] [int]    $TestDuration,
    # JMeter ramp-up window (seconds). 0 = fall back to userAmount (legacy
    # ~1-thread/sec ramp); the 'ramp' profile passes the full duration.
    [int]    $RampTime = 0,
    # Load profile name, carried per-case so generate-loadtest-config can key the
    # ramp criteria on the profile (scenario.yaml can't override the profile,
    # unlike users/spawn/duration).
    [string] $LoadProfile = '',
    [string] $WorkspaceRoot = $PWD
)

$ErrorActionPreference = "Stop"

function Fail([string] $message) {
    Write-Host "##vso[task.logissue type=error]prepare-test-cases: $message"
    throw $message
}

# App Service app_settings is map(string), so leaf values become strings.
function Convert-LeafValue($value) {
    if ($null -eq $value) { return '' }
    if ($value -is [bool]) { return $value.ToString().ToLowerInvariant() }
    return [string]$value
}

# Flatten an appsettings.json tree to App Service envvar form (Section__Sub__Key).
# Null leaves are skipped (not emitted as empty-string env vars) — writing `null`
# in the overlay JSON means "leave the package's default in place", and an empty
# env var would override that default instead.
function ConvertTo-FlatAppSettings {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [AllowNull()] $Node,
        [string] $Prefix = ''
    )

    $result = @{}

    if ($null -eq $Node) { return $result }

    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($key in $Node.Keys) {
            $newPrefix = if ($Prefix) { "${Prefix}__${key}" } else { "$key" }
            $sub = ConvertTo-FlatAppSettings -Node $Node[$key] -Prefix $newPrefix
            foreach ($k in $sub.Keys) { $result[$k] = $sub[$k] }
        }
    }
    elseif ($Node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($prop in $Node.PSObject.Properties) {
            $newPrefix = if ($Prefix) { "${Prefix}__$($prop.Name)" } else { "$($prop.Name)" }
            $sub = ConvertTo-FlatAppSettings -Node $prop.Value -Prefix $newPrefix
            foreach ($k in $sub.Keys) { $result[$k] = $sub[$k] }
        }
    }
    elseif ($Node -is [System.Collections.IEnumerable] -and -not ($Node -is [string])) {
        $i = 0
        foreach ($item in $Node) {
            $newPrefix = if ($Prefix) { "${Prefix}__${i}" } else { "$i" }
            $sub = ConvertTo-FlatAppSettings -Node $item -Prefix $newPrefix
            foreach ($k in $sub.Keys) { $result[$k] = $sub[$k] }
            $i++
        }
    }
    else {
        $result[$Prefix] = Convert-LeafValue $Node
    }

    return $result
}

# Read loadProfile.{users,spawnRate,duration} from scenario.yaml. Small regex parser
# avoids a powershell-yaml dependency.
function Read-ScenarioYaml {
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [string] $Path)

    $result = @{ loadProfile = @{ users = $null; spawnRate = $null; duration = $null } }

    $lines = Get-Content -LiteralPath $Path | ForEach-Object {
        ($_ -replace '\s+#.*$', '') -replace '^#.*$', ''
    }

    $inLoadProfile = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*loadProfile\s*:\s*$') { $inLoadProfile = $true; continue }
        if ($line -match '^\S')                     { $inLoadProfile = $false }
        if ($inLoadProfile -and $line -match '^\s+(users|spawnRate|duration)\s*:\s*(\d+)\s*$') {
            $result.loadProfile[$Matches[1]] = [int]$Matches[2]
        }
    }

    return $result
}

# Levenshtein distance; case-insensitive via PowerShell's default -eq comparison
# (we want typos like 'default' → 'Default' to match). Jagged array because
# the int[,] subscript syntax is parser-flaky across PowerShell versions.
function Get-LevenshteinDistance {
    param([string] $a, [string] $b)
    if (-not $a) { return $b.Length }
    if (-not $b) { return $a.Length }
    $d = New-Object 'int[][]' ($a.Length + 1)
    for ($i = 0; $i -le $a.Length; $i++) {
        $d[$i] = New-Object 'int[]' ($b.Length + 1)
        $d[$i][0] = $i
    }
    for ($j = 0; $j -le $b.Length; $j++) { $d[0][$j] = $j }
    for ($i = 1; $i -le $a.Length; $i++) {
        for ($j = 1; $j -le $b.Length; $j++) {
            $cost = if ($a[$i - 1] -eq $b[$j - 1]) { 0 } else { 1 }
            $d[$i][$j] = [math]::Min(
                [math]::Min($d[$i - 1][$j] + 1, $d[$i][$j - 1] + 1),
                $d[$i - 1][$j - 1] + $cost
            )
        }
    }
    return $d[$a.Length][$b.Length]
}

# Closest existing folder name to a (mistyped) scenario; $null if nothing's plausibly close.
function Get-ClosestScenarioMatch {
    param([string] $Needle, [string[]] $Haystack)
    if (-not $Haystack -or $Haystack.Count -eq 0) { return $null }
    $best = $null
    $bestDist = [int]::MaxValue
    foreach ($candidate in $Haystack) {
        $dist = Get-LevenshteinDistance $Needle $candidate
        if ($dist -lt $bestDist) {
            $bestDist = $dist
            $best = $candidate
        }
    }
    # Suggest only when the distance looks like a typo, not a wholly different name.
    $threshold = [math]::Max(2, [int]($Needle.Length / 2))
    if ($bestDist -le $threshold) { return $best }
    return $null
}

# --- Inputs ---

if ([string]::IsNullOrWhiteSpace($TestCasesJson)) {
    Fail "no testCases JSON provided (pass -TestCasesJson or set TEST_CASES_JSON env var)"
}
try {
    $cases = $TestCasesJson | ConvertFrom-Json
} catch {
    Fail "could not parse TestCasesJson: $($_.Exception.Message)"
}
if ($null -eq $cases -or @($cases).Count -eq 0) {
    Fail "testCases is empty"
}
# Force-wrap single-element arrays (ConvertFrom-Json unwraps them).
$cases = @($cases)

$tiersFile = Join-Path $WorkspaceRoot 'loadtests/tiers.json'
if (-not (Test-Path $tiersFile)) {
    Fail "tier catalog not found at $tiersFile"
}
try {
    $tierCatalogObj = Get-Content -Raw $tiersFile | ConvertFrom-Json
} catch {
    Fail "loadtests/tiers.json is invalid JSON: $($_.Exception.Message)"
}
$validTiers = @($tierCatalogObj.tiers.PSObject.Properties.Name)

# Enumerate scenario folders once for case-strict matching below.
$scenariosRoot = Join-Path $WorkspaceRoot 'loadtests/scenarios'
if (-not (Test-Path -LiteralPath $scenariosRoot -PathType Container)) {
    Fail "scenarios root folder not found: loadtests/scenarios/"
}
$scenarioFolders = @(Get-ChildItem -LiteralPath $scenariosRoot -Directory | ForEach-Object { $_.Name })
Write-Host "Available scenarios: $($scenarioFolders -join ', ')"

# --- Process each case ---

$tfTestCases       = [ordered]@{}
$resolvedTestCases = [ordered]@{}
$seenTestCaseIds   = @{}
$caseIndex         = 0

foreach ($case in $cases) {
    $caseIndex++

    # IsNullOrWhiteSpace covers missing, null, and empty.
    foreach ($field in @('umbraco', 'dotnet', 'scenario')) {
        if ([string]::IsNullOrWhiteSpace([string]$case.$field)) {
            Fail "case ${caseIndex}: missing required field '$field'"
        }
    }

    # Supported range is v13–v18. The .NET runtime + seeder package version maps
    # in resolve-run-config.ps1 and install-umbraco-cms-on-appservice.ps1 must
    # know each major; resolve-run-config catches new majors with an explicit
    # error. Here we just enforce the lower bound + parse.
    # Free text from the queue UI that reaches an Azure resource name, a
    # hand-escaped `terraform -var`, and a `pwsh -Command` string - so restrict it
    # to what Azure names accept, which also excludes shell metacharacters.
    if ([string]$case.umbraco -notmatch '^[0-9A-Za-z][0-9A-Za-z.\-]*$') {
        Fail "case ${caseIndex}: umbraco version '$($case.umbraco)' must contain only letters, digits, dots and hyphens (it becomes part of Azure resource names and is passed to the deploy script)"
    }
    if (([string]$case.umbraco).Length -gt 30) {
        Fail "case ${caseIndex}: umbraco version '$($case.umbraco)' is $(([string]$case.umbraco).Length) chars (max 30) - it participates in the 60-char App Service name budget"
    }
    $umbracoMajorRaw = ([string]$case.umbraco).Split('.')[0]
    $umbracoMajor    = 0
    if (-not [int]::TryParse($umbracoMajorRaw, [ref]$umbracoMajor)) {
        Fail "case ${caseIndex}: cannot parse umbraco version '$($case.umbraco)' (expected X.Y.Z)"
    }
    if ($umbracoMajor -lt 13) {
        Fail "case ${caseIndex}: umbraco version '$($case.umbraco)' is unsupported (this pipeline targets v13+)"
    }

    # Scenarios with v17-only code overlays (e.g. DeliveryApi's Program.cs uses
    # v17's builder shape). Reject the combination here so the run fails fast
    # instead of breaking at dotnet build inside the install script.
    $v17OnlyScenarios = @('DeliveryApi')
    if ($v17OnlyScenarios -contains $case.scenario -and $umbracoMajor -lt 17) {
        Fail "case ${caseIndex}: scenario '$($case.scenario)' requires Umbraco 17+ (got '$($case.umbraco)'). Use the Default scenario for older majors."
    }

    $hasTiers = $case.PSObject.Properties.Name -contains 'tiers'
    if (-not $hasTiers) {
        Fail "case ${caseIndex}: missing required field 'tiers' (e.g. tiers: ['Standard'] or ['Starter','Standard','Pro'])"
    }
    $caseTiers = @($case.tiers)
    if ($caseTiers.Count -eq 0) {
        Fail "case ${caseIndex}: 'tiers' array is empty"
    }

    # Scenario name participates in Azure resource names (App Service <= 60 chars).
    if ($case.scenario.Length -gt 15) {
        Fail "case ${caseIndex}: scenario name '$($case.scenario)' is $($case.scenario.Length) chars (max 15)"
    }
    if ($case.scenario -notmatch '^[A-Za-z0-9][-A-Za-z0-9]*$') {
        Fail "case ${caseIndex}: scenario name '$($case.scenario)' must be alphanumeric + hyphens"
    }

    # Match scenario folder case-strictly so a local 'default' doesn't pass while the folder is 'Default/'.
    if ($scenarioFolders -cnotcontains $case.scenario) {
        $suggestion = Get-ClosestScenarioMatch -Needle $case.scenario -Haystack $scenarioFolders
        $hint = if ($suggestion) { " (did you mean '$suggestion'?)" } else { '' }
        Fail "case ${caseIndex}: scenario folder not found: loadtests/scenarios/$($case.scenario)$hint"
    }
    $scenarioDir = Join-Path $scenariosRoot $case.scenario
    $appSettingsFile = Join-Path $scenarioDir 'AdditionalSetup/appsettings.json'
    # AdditionalSetup/appsettings.json is optional — a scenario with no Umbraco
    # config overlay can omit the file (or ship `{}`). When present, it must
    # be valid JSON.
    if (Test-Path $appSettingsFile) {
        try {
            $appsettingsObj = Get-Content -Raw $appSettingsFile | ConvertFrom-Json
        } catch {
            Fail "case ${caseIndex}: scenario '$($case.scenario)' has invalid appsettings.json: $($_.Exception.Message)"
        }
        $overlay = ConvertTo-FlatAppSettings -Node $appsettingsObj
    } else {
        $overlay = @{}
    }

    # Resolve load profile: scenario.yaml overrides win over pipeline defaults.
    $effUsers    = $UserAmount
    $effSpawn    = $SpawnRate
    $effDuration = $TestDuration

    $scenarioYaml = Join-Path $scenarioDir 'scenario.yaml'
    if (Test-Path $scenarioYaml) {
        try {
            $meta = Read-ScenarioYaml -Path $scenarioYaml
        } catch {
            Fail "case ${caseIndex}: scenario '$($case.scenario)' has invalid scenario.yaml: $($_.Exception.Message)"
        }
        if ($null -ne $meta.loadProfile.users)     { $effUsers    = [int]$meta.loadProfile.users }
        if ($null -ne $meta.loadProfile.spawnRate) { $effSpawn    = [int]$meta.loadProfile.spawnRate }
        if ($null -ne $meta.loadProfile.duration)  { $effDuration = [int]$meta.loadProfile.duration }
    }

    if ($effUsers -lt 1 -or $effUsers -gt 1000) {
        Fail "case ${caseIndex}: resolved userAmount '$effUsers' out of range (1-1000)."
    }
    if ($effSpawn -lt 1 -or $effSpawn -gt 100) {
        Fail "case ${caseIndex}: resolved spawnRate '$effSpawn' out of range (1-100)."
    }
    if ($effDuration -lt 30 -or $effDuration -gt 7200) {
        Fail "case ${caseIndex}: resolved testDuration '$effDuration' out of range (30-7200 seconds)."
    }

    # rampTime drives the JMeter thread-group ramp. Default (0) falls back to the
    # final thread count, reproducing the legacy ~1-thread/sec ramp; the 'ramp'
    # profile passes the full duration so load climbs across the whole run.
    $effRampTime = if ($RampTime -gt 0) { $RampTime } else { $effUsers }
    if ($effRampTime -lt 1 -or $effRampTime -gt 7200) {
        Fail "case ${caseIndex}: resolved rampTime '$effRampTime' out of range (1-7200 seconds)."
    }

    # Expand: one input entry x N tiers -> N test cases.
    foreach ($tierName in $caseTiers) {
        if ($validTiers -notcontains $tierName) {
            Fail "case ${caseIndex}: tier '$tierName' is not in tiers.json (known: $($validTiers -join ', '))"
        }
        # -notcontains matched case-insensitively above, so normalize to the
        # canonical casing from tiers.json - a hand-authored -TestCasesJson
        # (this script's standalone entrypoint) with e.g. tiers: ['standard']
        # would otherwise pass validation but flow lowercase into testCaseId/
        # tier/the Terraform var, which may do an exact-case lookup.
        $tierName = @($validTiers | Where-Object { $_ -ieq $tierName })[0]

        # Keep this format in sync with the compile-time testCaseId in azure-pipeline.yml.
        $testCaseId = "$($case.umbraco)__${tierName}__$($case.scenario)"
        if ($seenTestCaseIds.ContainsKey($testCaseId)) {
            Fail "case ${caseIndex}: duplicate testCaseId '$testCaseId' (already used by case $($seenTestCaseIds[$testCaseId]))."
        }
        $seenTestCaseIds[$testCaseId] = $caseIndex

        $tfTestCases[$testCaseId] = [ordered]@{
            dotnet_version       = [string]$case.dotnet
            umbraco_version      = [string]$case.umbraco
            tier                 = [string]$tierName
            scenario             = [string]$case.scenario
            app_settings_overlay = $overlay
        }

        $resolvedTestCases[$testCaseId] = [ordered]@{
            userAmount   = $effUsers
            spawnRate    = $effSpawn
            testDuration = $effDuration
            rampTime     = $effRampTime
            loadProfile  = $LoadProfile
            label        = "$($case.umbraco)/${tierName}/$($case.scenario)"
        }
    }
}

# --- Emit ---

$tfJson  = $tfTestCases       | ConvertTo-Json -Compress -Depth 10
$resJson = $resolvedTestCases | ConvertTo-Json -Compress -Depth 10

# Escape " for shell-compat: testCasesJson flows into terraform -var="...".
$tfJsonEscaped = $tfJson.Replace('"', '\"')

Write-Host "##vso[task.setvariable variable=testCasesJson;isOutput=true]$tfJsonEscaped"
Write-Host "##vso[task.setvariable variable=resolvedTestCases;isOutput=true]$resJson"

Write-Host ""
$inputCount    = $cases.Count
$expandedCount = $tfTestCases.Keys.Count
if ($inputCount -eq $expandedCount) {
    Write-Host "Validated $expandedCount test case(s):"
} else {
    Write-Host "Validated $inputCount input entries -> $expandedCount test cases (expanded across tiers):"
}
foreach ($testCaseId in $tfTestCases.Keys) {
    $r = $resolvedTestCases[$testCaseId]
    Write-Host "  - $testCaseId   users=$($r.userAmount) spawnRate=$($r.spawnRate) duration=$($r.testDuration)s"
}
