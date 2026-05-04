# Publish load test results to history storage:
#   {scenario}/{major}/{umbracoVersion}/{tier}/{yyyy-MM-dd}_{buildId}/summary.ndjson  (one row per Locust task)
#   {scenario}/{major}/{umbracoVersion}/{tier}/{yyyy-MM-dd}_{buildId}/raw/...         (full load test artifact dump)
#
# Scenario is top-level because it defines what's *comparable*: different scenarios
# hit different endpoints / seed different data, so their numbers can't be compared.
# Within a scenario, version and tier are the pivots you actually want to sweep.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$ResultsDir,
    [Parameter(Mandatory = $true)] [string]$HistoryResourceGroup,
    [Parameter(Mandatory = $true)] [string]$StorageAccountName,
    [Parameter(Mandatory = $true)] [string]$ContainerName,

    [Parameter(Mandatory = $true)] [string]$BuildId,
    [Parameter(Mandatory = $true)] [string]$Commit,
    [Parameter(Mandatory = $true)] [string]$Branch,
    [Parameter(Mandatory = $true)] [string]$RunStartedAt,

    [Parameter(Mandatory = $true)] [string]$UmbracoVersion,
    [Parameter(Mandatory = $true)] [string]$DotNetVersion,
    [Parameter(Mandatory = $true)] [string]$AppServiceSku,
    [Parameter(Mandatory = $true)] [string]$SqlSku,
    [Parameter(Mandatory = $true)] [string]$SeederPreset,
    [Parameter(Mandatory = $true)] [string]$Tier,
    [Parameter(Mandatory = $true)] [string]$Scenario,
    [Parameter(Mandatory = $true)] [int]$UserCount,
    [Parameter(Mandatory = $true)] [int]$SpawnRate,
    [Parameter(Mandatory = $true)] [int]$DurationSeconds,
    [Parameter(Mandatory = $true)] [string]$ColdStart,
    [Parameter(Mandatory = $true)] [string]$TestCaseId
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $ResultsDir)) {
    Write-Warning "Results dir '$ResultsDir' not found - nothing to publish."
    exit 0
}

# Carried into every row so cross-run queries don't need joins.
$metadata = [ordered]@{
    run_id           = $BuildId
    test_case_id     = $TestCaseId
    commit           = $Commit
    branch           = $Branch
    run_started_at   = $RunStartedAt
    umbraco_version  = $UmbracoVersion
    dotnet_version   = $DotNetVersion
    app_service_sku  = $AppServiceSku
    sql_sku          = $SqlSku
    seeder_preset    = $SeederPreset
    infra_tier       = $Tier
    scenario         = $Scenario
    user_count       = $UserCount
    spawn_rate       = $SpawnRate
    duration_seconds = $DurationSeconds
    cold_start       = [bool]::Parse($ColdStart)
}

# Locust output filenames vary; try a few patterns and take the first match.
$candidates = @("*_stats.csv", "stats.csv", "results.csv", "clientResults*.csv")
$statsFile = $null
foreach ($pattern in $candidates) {
    $statsFile = Get-ChildItem -Path $ResultsDir -Recurse -Filter $pattern -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($statsFile) { break }
}

$rows = @()
if ($statsFile) {
    Write-Host "Parsing $($statsFile.FullName)"
    $stats = Import-Csv $statsFile.FullName
    foreach ($row in $stats) {
        $name = $row.Name
        if ([string]::IsNullOrWhiteSpace($name) -or $name -eq 'Aggregated') { continue }

        $reqCount  = [int]($row.'Request Count' ?? 0)
        $failCount = [int]($row.'Failure Count' ?? 0)
        $errorRate = if ($reqCount -gt 0) { [math]::Round($failCount / $reqCount, 4) } else { 0 }

        $merged = [ordered]@{}
        foreach ($k in $metadata.Keys) { $merged[$k] = $metadata[$k] }
        $merged.scenario_name    = $name
        $merged.request_type     = $row.Type
        $merged.request_count    = $reqCount
        $merged.failure_count    = $failCount
        $merged.error_rate       = $errorRate
        $merged.avg_ms           = [double]($row.'Average Response Time' ?? 0)
        $merged.median_ms        = [double]($row.'Median Response Time' ?? 0)
        $merged.p50_ms           = [double]($row.'50%' ?? 0)
        $merged.p90_ms           = [double]($row.'90%' ?? 0)
        $merged.p95_ms           = [double]($row.'95%' ?? 0)
        $merged.p99_ms           = [double]($row.'99%' ?? 0)
        $merged.min_ms           = [double]($row.'Min Response Time' ?? 0)
        $merged.max_ms           = [double]($row.'Max Response Time' ?? 0)
        $merged.requests_per_sec = [double]($row.'Requests/s' ?? 0)
        $rows += [pscustomobject]$merged
    }
    Write-Host "Parsed $($rows.Count) scenario row(s)."
}
else {
    Write-Warning "No Locust stats CSV found under '$ResultsDir' - emitting metadata-only record."
}

# Always emit at least the metadata so the run is searchable.
if ($rows.Count -eq 0) {
    $rows = @([pscustomobject]$metadata)
}

# Parse with InvariantCulture so the date stays consistent on any agent locale.
$pipelineStarted = [DateTime]::Parse($RunStartedAt, [System.Globalization.CultureInfo]::InvariantCulture)
$datePart        = $pipelineStarted.ToString("yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)

# Major = first dot-segment (e.g. '17' for '17.0.0' and '17.0.0-rc.1').
$majorVersion = ($UmbracoVersion -split '\.')[0]
if ([string]::IsNullOrWhiteSpace($majorVersion)) { $majorVersion = 'unknown' }

$blobPrefix = "$Scenario/$majorVersion/$UmbracoVersion/$Tier/${datePart}_$BuildId"
$summaryFile = Join-Path $ResultsDir "summary.ndjson"

$rows | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 } |
    Out-File -FilePath $summaryFile -Encoding utf8

$storageKey = az storage account keys list -n $StorageAccountName -g $HistoryResourceGroup --query "[0].value" -o tsv

Write-Host ""
Write-Host "Uploading to https://$StorageAccountName.blob.core.windows.net/$ContainerName/$blobPrefix/"

az storage blob upload `
    --account-name $StorageAccountName --account-key $storageKey `
    --container-name $ContainerName `
    --file $summaryFile `
    --name "$blobPrefix/summary.ndjson" `
    --overwrite | Out-Null

# Raw artifacts kept for analyses that need fields the summary doesn't surface.
az storage blob upload-batch `
    --account-name $StorageAccountName --account-key $storageKey `
    --destination $ContainerName `
    --destination-path "$blobPrefix/raw" `
    --source $ResultsDir `
    --pattern "*" `
    --overwrite | Out-Null

Write-Host "Published $($rows.Count) record(s) + raw artifacts."
