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
    [Parameter(Mandatory = $true)] [string]$TestCaseId,

    # Server-side metric query window + resource IDs. Queried via Azure Monitor
    # and injected into row metadata alongside the client-side latencies.
    [Parameter(Mandatory = $true)] [string]$LoadTestStartTime,
    [Parameter(Mandatory = $true)] [string]$LoadTestEndTime,
    [Parameter(Mandatory = $true)] [string]$AppServiceResourceId,
    [Parameter(Mandatory = $true)] [string]$AppServicePlanResourceId,
    [Parameter(Mandatory = $true)] [string]$SqlDatabaseResourceId,

    # Optional Logs Ingestion API target. When all three are provided, the
    # script POSTs each row to a Log Analytics custom table in addition to the
    # blob upload (the Workbook reads from there). Provisioned by
    # scripts/ensure-monitoring-infra.ps1 — that script prints these three values.
    [string]$LogAnalyticsDceUri,
    [string]$LogAnalyticsDcrImmutableId,
    [string]$LogAnalyticsStreamName
)

$ErrorActionPreference = "Stop"

# Make native commands (az CLI) honour $ErrorActionPreference so a failed blob upload
# fails the publish step instead of silently exiting 0. Requires pwsh 7.3+.
$PSNativeCommandUseErrorActionPreference = $true

. "$PSScriptRoot/_helpers.ps1"

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

# Server-side metrics from Azure Monitor over the load-test window. Latency-only
# data can't tell you whether p99 regressed because of code, SQL DTU saturation,
# or App Service CPU pegging — these fields close that gap. When the metric
# query fails (network, missing role, no data points yet due to ingestion lag),
# warn and continue with client-side metrics only; don't fail the whole publish.
function Get-MetricSummary {
    param(
        [Parameter(Mandatory)] [string]$ResourceId,
        [Parameter(Mandatory)] [string[]]$Metrics,
        [Parameter(Mandatory)] [string]$StartTime,
        [Parameter(Mandatory)] [string]$EndTime
    )
    $result = @{}
    try {
        $json = az monitor metrics list `
            --resource $ResourceId `
            --metric ($Metrics -join ',') `
            --aggregation Average `
            --start-time $StartTime `
            --end-time $EndTime `
            --interval PT1M `
            -o json
        $data = $json | ConvertFrom-Json
        foreach ($metric in $data.value) {
            $name = $metric.name.value
            $points = @()
            if ($metric.timeseries.Count -gt 0) {
                $points = @($metric.timeseries[0].data | Where-Object { $null -ne $_.average })
            }
            if ($points.Count -eq 0) {
                $result["${name}_avg"] = $null
                $result["${name}_max"] = $null
                continue
            }
            $values = @($points | ForEach-Object { [double]$_.average })
            $result["${name}_avg"] = [math]::Round((($values | Measure-Object -Average).Average), 2)
            $result["${name}_max"] = [math]::Round((($values | Measure-Object -Maximum).Maximum), 2)
        }
    } catch {
        Write-Warning "Azure Monitor query failed for $ResourceId : $($_.Exception.Message)"
    }
    return $result
}

Write-Host ""
Write-Host "Querying Azure Monitor for server-side metrics over [$LoadTestStartTime, $LoadTestEndTime]..."

$planMetrics = Get-MetricSummary `
    -ResourceId $AppServicePlanResourceId `
    -Metrics @("CpuPercentage", "MemoryPercentage") `
    -StartTime $LoadTestStartTime -EndTime $LoadTestEndTime
foreach ($k in $planMetrics.Keys) { $metadata["plan_$k"] = $planMetrics[$k] }

$sqlMetrics = Get-MetricSummary `
    -ResourceId $SqlDatabaseResourceId `
    -Metrics @("dtu_consumption_percent", "cpu_percent", "log_write_percent", "physical_data_read_percent") `
    -StartTime $LoadTestStartTime -EndTime $LoadTestEndTime
foreach ($k in $sqlMetrics.Keys) { $metadata["sql_$k"] = $sqlMetrics[$k] }

$appMetrics = Get-MetricSummary `
    -ResourceId $AppServiceResourceId `
    -Metrics @("Http5xx", "Http4xx") `
    -StartTime $LoadTestStartTime -EndTime $LoadTestEndTime
foreach ($k in $appMetrics.Keys) { $metadata["app_$k"] = $appMetrics[$k] }

# ALT emits engine{N}_results.csv (JMeter format) — raw per-request data, one
# row per HTTP call. Header: timeStamp, elapsed, label, responseCode,
# responseMessage, threadName, dataType, success, failureMessage, ...
# Multi-engine runs produce one CSV per engine; we aggregate across all of them.
# Get-Pct and Parse-JmeterCsv are provided by _helpers.ps1.

$rows = @()

# Azure Load Testing's task downloads its artifacts as results.zip (and
# report.zip) but doesn't unpack them. The engine*_results.csv we scan for
# below lives INSIDE results.zip, so without this expansion every run produces
# a metadata-only row (parse_status="no_metrics") and the Workbook filters it
# out as missing real metrics.
$resultsZips = @(Get-ChildItem -Path $ResultsDir -Recurse -Filter "results.zip" -File -ErrorAction SilentlyContinue)
foreach ($zip in $resultsZips) {
    $dest = Join-Path $zip.Directory.FullName ($zip.BaseName + "-extracted")
    if (-not (Test-Path $dest)) {
        Expand-Archive -Path $zip.FullName -DestinationPath $dest -Force
        Write-Host "Extracted $($zip.Name) to $dest"
    }
}

$engineFiles = @(Get-ChildItem -Path $ResultsDir -Recurse -Filter "engine*_results.csv" -File -ErrorAction SilentlyContinue)
if ($engineFiles.Count -gt 0) {
    Write-Host "Parsing $($engineFiles.Count) engine result file(s) (JMeter format):"
    $engineFiles | ForEach-Object { Write-Host "  - $($_.FullName)" }
    $metadata.parse_status = "ok"

    # Parse each engine CSV via the shared parser (Parse-JmeterCsv in _helpers.ps1);
    # merge the per-label buckets across engines. Single-engine runs trivially
    # become one parse call; multi-engine runs concatenate samples per label.
    $byLabel = @{}
    foreach ($file in $engineFiles) {
        $parsed = Parse-JmeterCsv -Path $file.FullName
        foreach ($kv in $parsed.ByLabel.GetEnumerator()) {
            $merged = $byLabel[$kv.Key]
            if (-not $merged) {
                $merged = @{
                    Samples = (New-Object 'System.Collections.Generic.List[int]')
                    Errors  = 0
                }
                $byLabel[$kv.Key] = $merged
            }
            $merged.Samples.AddRange($kv.Value.Samples)
            $merged.Errors += $kv.Value.Errors
        }
    }

    $testDurationSec = [double]$DurationSeconds

    foreach ($label in $byLabel.Keys) {
        $bucket = $byLabel[$label]
        $sorted = [System.Collections.Generic.List[int]]::new($bucket.Samples)
        $sorted.Sort()

        $reqCount  = $sorted.Count
        $failCount = $bucket.Errors
        $errorRate = if ($reqCount -gt 0) { [math]::Round($failCount / $reqCount, 4) } else { 0 }
        $rps       = if ($testDurationSec -gt 0 -and $reqCount -gt 0) { [math]::Round($reqCount / $testDurationSec, 2) } else { 0 }
        $avg       = if ($reqCount -gt 0) { [int](($sorted | Measure-Object -Average).Average) } else { 0 }

        $merged = [ordered]@{}
        foreach ($k in $metadata.Keys) { $merged[$k] = $metadata[$k] }
        $merged.scenario_name    = $label
        $merged.request_type     = "HTTP"  # JMeter format doesn't carry the Locust task type
        $merged.request_count    = $reqCount
        $merged.failure_count    = $failCount
        $merged.error_rate       = $errorRate
        $merged.avg_ms           = $avg
        $merged.p50_ms           = Get-Pct $sorted 50
        $merged.p90_ms           = Get-Pct $sorted 90
        $merged.p95_ms           = Get-Pct $sorted 95
        $merged.p99_ms           = Get-Pct $sorted 99
        $merged.min_ms           = if ($reqCount -gt 0) { $sorted[0] } else { 0 }
        $merged.max_ms           = if ($reqCount -gt 0) { $sorted[$sorted.Count - 1] } else { 0 }
        $merged.requests_per_sec = $rps
        $merged.engine_count     = $engineFiles.Count
        $rows += [pscustomobject]$merged
    }
    Write-Host "Parsed $($rows.Count) sampler row(s) from $($engineFiles.Count) engine file(s)."
}
else {
    Write-Warning "No engine_results.csv found under '$ResultsDir' - emitting metadata-only record."
    $metadata.parse_status = "no_metrics"
}

# Always emit at least the metadata so the run is searchable. Downstream queries
# can filter on parse_status to distinguish real metric rows from placeholder rows.
# If a parser branch ran but produced zero rows (CSVs present but empty / malformed),
# downgrade parse_status so the fallback row doesn't claim "ok" with no data.
if ($rows.Count -eq 0) {
    if ($metadata.parse_status -eq "ok") { $metadata.parse_status = "ok_no_samples" }
    $rows = @([pscustomobject]$metadata)
}

# Parse with InvariantCulture so the date stays consistent on any agent locale.
$pipelineStarted = [DateTime]::Parse($RunStartedAt, [System.Globalization.CultureInfo]::InvariantCulture)
$datePart        = $pipelineStarted.ToString("yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)

# Major = first dot-segment (e.g. '17' for '17.0.0' and '17.0.0-rc.1').
$majorVersion = (Get-UmbracoMajor $UmbracoVersion).ToString()

$blobPrefix = "$Scenario/$majorVersion/$UmbracoVersion/$Tier/${datePart}_$BuildId"
# Write the summary OUTSIDE $ResultsDir so the upload-batch below (which uploads
# everything in $ResultsDir to /raw) doesn't end up duplicating it under raw/.
$summaryFile = Join-Path (Split-Path -Parent $ResultsDir) "summary.ndjson"

$rows | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 } |
    Out-File -FilePath $summaryFile -Encoding utf8

$storageKey = Get-StorageAccountKey -StorageAccountName $StorageAccountName -ResourceGroupName $HistoryResourceGroup

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

# Logs Ingestion API: send the same rows to the Log Analytics custom table that
# backs the Workbook. Same defensive posture as the Azure Monitor metric query
# above — failure here warns and continues; the blob upload is the source of
# truth for raw data, this is the queryable mirror.
if ($LogAnalyticsDceUri -and $LogAnalyticsDcrImmutableId -and $LogAnalyticsStreamName) {
    Write-Host ""
    Write-Host "Posting $($rows.Count) row(s) to Log Analytics ($LogAnalyticsStreamName)"
    try {
        $token = az account get-access-token --resource https://monitor.azure.com --query accessToken -o tsv
        # The DCR expects TimeGenerated on every row; carry the run start time so
        # all per-sampler rows of one run share a single point on the time axis.
        $ingestRows = $rows | ForEach-Object {
            $row = $_ | Select-Object *
            $row | Add-Member -NotePropertyName TimeGenerated -NotePropertyValue $RunStartedAt -Force
            $row
        }
        # -AsArray forces array shape even for a single row; the Logs Ingestion API
        # rejects a bare JSON object.
        $body = ConvertTo-Json -InputObject @($ingestRows) -Depth 5 -Compress -AsArray
        $url  = "$LogAnalyticsDceUri/dataCollectionRules/$LogAnalyticsDcrImmutableId/streams/${LogAnalyticsStreamName}?api-version=2023-01-01"
        Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType "application/json" `
            -Headers @{ Authorization = "Bearer $token" } | Out-Null
        Write-Host "   ok"
    }
    catch {
        # Surface to BOTH the task log and the AzDO summary panel so a stretch
        # of silent partial-publish failures actually gets noticed before the
        # Workbook starts looking stale. Pipeline still succeeds (continueOnError
        # on the publish task) — the issue surfaces as a warning, not a fail.
        $msg = "Log Analytics ingestion failed: $($_.Exception.Message). Blob upload succeeded; data is recoverable via backfill-monitoring.ps1."
        Write-Warning $msg
        Write-Host "##vso[task.logissue type=warning]$msg"
    }
}
