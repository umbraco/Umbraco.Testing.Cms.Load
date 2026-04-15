# Publishes load test results from a single AzureLoadTest@1 invocation to the
# long-lived history storage account.
#
# Output layout in the blob container:
#   runs/{yyyy/MM/dd}/{buildId}/test-{testIndex}/summary.ndjson   <- one row per scenario, ready for ADX/Kusto/pandas
#   runs/{yyyy/MM/dd}/{buildId}/test-{testIndex}/raw/...          <- full ALT artifact dump for forensic deep-dives
#
# The summary is the canonical comparison surface — every row is enriched with
# the run + config metadata so cross-run queries don't need joins. The raw dump
# is preserved so future analysis can reach for fields the parser doesn't know
# about today.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$ResultsDir,
    [Parameter(Mandatory = $true)] [string]$HistoryResourceGroup,
    [Parameter(Mandatory = $true)] [string]$StorageAccountName,
    [Parameter(Mandatory = $true)] [string]$ContainerName,

    # Run metadata
    [Parameter(Mandatory = $true)] [string]$BuildId,
    [Parameter(Mandatory = $true)] [string]$Commit,
    [Parameter(Mandatory = $true)] [string]$Branch,
    [Parameter(Mandatory = $true)] [string]$RunStartedAt,

    # Per-test config — carried into every scenario row so comparisons can filter
    [Parameter(Mandatory = $true)] [string]$UmbracoVersion,
    [Parameter(Mandatory = $true)] [string]$DotNetVersion,
    [Parameter(Mandatory = $true)] [string]$AppServiceSku,
    [Parameter(Mandatory = $true)] [string]$SqlSku,
    [Parameter(Mandatory = $true)] [string]$SeederPreset,
    [Parameter(Mandatory = $true)] [int]$UserCount,
    [Parameter(Mandatory = $true)] [int]$SpawnRate,
    [Parameter(Mandatory = $true)] [int]$DurationSeconds,
    [Parameter(Mandatory = $true)] [string]$ColdStart,        # "True" / "False" — converted below
    [Parameter(Mandatory = $true)] [int]$TestIndex
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $ResultsDir)) {
    Write-Warning "Results dir '$ResultsDir' not found — nothing to publish."
    exit 0
}

# Canonical metadata applied to every row + the run-level summary
$metadata = [ordered]@{
    run_id            = $BuildId
    test_index        = $TestIndex
    commit            = $Commit
    branch            = $Branch
    run_started_at    = $RunStartedAt
    umbraco_version   = $UmbracoVersion
    dotnet_version    = $DotNetVersion
    app_service_sku   = $AppServiceSku
    sql_sku           = $SqlSku
    seeder_preset     = $SeederPreset
    user_count        = $UserCount
    spawn_rate        = $SpawnRate
    duration_seconds  = $DurationSeconds
    cold_start        = [bool]::Parse($ColdStart)
}

# Locate the Locust stats CSV. ALT downloads vary in naming — search a few
# common patterns and take the first match. Aggregated rows are filtered out
# below so each (test x request) becomes one record.
$candidates = @(
    "*_stats.csv", "stats.csv", "results.csv", "clientResults*.csv"
)
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

        $reqCount = [int]($row.'Request Count' ?? 0)
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
    Write-Warning "No Locust stats CSV found under '$ResultsDir' — emitting metadata-only record."
}

# Always emit at least the metadata record so the run is searchable in history,
# even when the parser comes up empty.
if ($rows.Count -eq 0) {
    $rows = @([pscustomobject]$metadata)
}

$datePart = (Get-Date -Date $RunStartedAt -Format "yyyy/MM/dd")
$blobPrefix = "runs/$datePart/$BuildId/test-$TestIndex"
$summaryFile = Join-Path $ResultsDir "summary.ndjson"

# NDJSON — one JSON object per line, append-friendly, trivially ingested by
# Kusto / pandas / Postgres / Spark.
$rows | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 } |
    Out-File -FilePath $summaryFile -Encoding utf8

# Account key auth — same rationale as the bootstrap script.
$storageKey = az storage account keys list -n $StorageAccountName -g $HistoryResourceGroup --query "[0].value" -o tsv

Write-Host ""
Write-Host "Uploading to https://$StorageAccountName.blob.core.windows.net/$ContainerName/$blobPrefix/"

az storage blob upload `
    --account-name $StorageAccountName --account-key $storageKey `
    --container-name $ContainerName `
    --file $summaryFile `
    --name "$blobPrefix/summary.ndjson" `
    --overwrite | Out-Null

# Raw artifacts — uploaded once per test for future analyses that need data
# the summary parser doesn't surface.
az storage blob upload-batch `
    --account-name $StorageAccountName --account-key $storageKey `
    --destination $ContainerName `
    --destination-path "$blobPrefix/raw" `
    --source $ResultsDir `
    --pattern "*" `
    --overwrite | Out-Null

Write-Host "Published $($rows.Count) record(s) + raw artifacts."
