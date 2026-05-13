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
    [Parameter(Mandatory = $true)] [string]$SkipWarmup,
    [Parameter(Mandatory = $true)] [string]$TestCaseId,

    # Optional server-side metric query window + resource IDs. When all five are
    # provided, the script queries Azure Monitor for App Service Plan + SQL DB
    # metrics over the window and injects mean/max into the row metadata. Empty
    # (e.g. when called outside the pipeline) falls back to client-side metrics only.
    [string]$LoadTestStartTime,
    [string]$LoadTestEndTime,
    [string]$AppServiceResourceId,
    [string]$AppServicePlanResourceId,
    [string]$SqlDatabaseResourceId
)

$ErrorActionPreference = "Stop"

# Make native commands (az CLI) honour $ErrorActionPreference so a failed blob upload
# fails the publish step instead of silently exiting 0. Requires pwsh 7.3+.
$PSNativeCommandUseErrorActionPreference = $true

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
    # Schema name stays `cold_start` — it describes the test condition
    # (was warmup skipped, i.e. cold-start exercised). $SkipWarmup is the
    # procedural pipeline-side phrasing; both mean the same boolean.
    cold_start       = [bool]::Parse($SkipWarmup)
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

if ($LoadTestStartTime -and $LoadTestEndTime) {
    Write-Host ""
    Write-Host "Querying Azure Monitor for server-side metrics over [$LoadTestStartTime, $LoadTestEndTime]..."

    if ($AppServicePlanResourceId) {
        $planMetrics = Get-MetricSummary `
            -ResourceId $AppServicePlanResourceId `
            -Metrics @("CpuPercentage", "MemoryPercentage") `
            -StartTime $LoadTestStartTime -EndTime $LoadTestEndTime
        foreach ($k in $planMetrics.Keys) { $metadata["plan_$k"] = $planMetrics[$k] }
    }

    if ($SqlDatabaseResourceId) {
        $sqlMetrics = Get-MetricSummary `
            -ResourceId $SqlDatabaseResourceId `
            -Metrics @("dtu_consumption_percent", "cpu_percent", "log_write_percent", "physical_data_read_percent") `
            -StartTime $LoadTestStartTime -EndTime $LoadTestEndTime
        foreach ($k in $sqlMetrics.Keys) { $metadata["sql_$k"] = $sqlMetrics[$k] }
    }

    if ($AppServiceResourceId) {
        $appMetrics = Get-MetricSummary `
            -ResourceId $AppServiceResourceId `
            -Metrics @("Http5xx", "Http4xx") `
            -StartTime $LoadTestStartTime -EndTime $LoadTestEndTime
        foreach ($k in $appMetrics.Keys) { $metadata["app_$k"] = $appMetrics[$k] }
    }
}

# Two possible CSV shapes from a Locust run on Azure Load Testing:
#
#   1. engine{N}_results.csv — JMeter-format raw per-request data, one row per
#      HTTP call. Header: timeStamp,elapsed,label,responseCode,responseMessage,
#      threadName,dataType,success,failureMessage,bytes,sentBytes,...
#      This is what ALT actually emits. Stream-parse and aggregate per `label`.
#
#   2. *_stats.csv (or stats.csv / results.csv / clientResults*.csv) —
#      Locust's pre-aggregated stats with one row per task (Name, Request Count,
#      Average Response Time, 50%, 95%, 99%, ...). Locust direct-runs emit this;
#      ALT does NOT.
#
# We try (1) first because it's what ALT emits in practice, then fall back to
# (2) for local Locust runs / offline analysis. Multi-engine runs produce one
# CSV per engine; we aggregate across all matching files.

function Get-Pct ($Sorted, [double]$Pct) {
    if ($Sorted.Count -eq 0) { return 0 }
    # Nearest-rank: ceil(N * pct / 100) - 1, clamped.
    $i = [int][math]::Ceiling($Sorted.Count * $Pct / 100.0) - 1
    if ($i -lt 0) { $i = 0 }
    if ($i -gt $Sorted.Count - 1) { $i = $Sorted.Count - 1 }
    return $Sorted[$i]
}

$rows = @()

# Azure Load Testing's task downloads run artifacts as results.zip (and
# report.zip) and doesn't unpack them. The engine*_results.csv we scan for
# below lives INSIDE results.zip, so without this expansion every run
# would silently fall through to parse_status="no_metrics" and produce a
# metadata-only NDJSON row with no latency data.
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

    # Stream-parse each engine CSV, bucketing samples by Locust task name (column 2).
    # Memory-bounded — we keep the per-task sample list, not the whole file.
    $byLabel = @{}
    foreach ($file in $engineFiles) {
        $reader = [System.IO.StreamReader]::new($file.FullName)
        try {
            $reader.ReadLine() | Out-Null  # discard header
            while ($null -ne ($line = $reader.ReadLine())) {
                $cols = $line.Split(',')
                if ($cols.Length -lt 8) { continue }
                $elapsed = 0
                if (-not [int]::TryParse($cols[1], [ref]$elapsed)) { continue }
                $label   = $cols[2]
                $success = $cols[7] -eq 'TRUE' -or $cols[7] -eq 'true'

                $bucket = $byLabel[$label]
                if (-not $bucket) {
                    $bucket = @{
                        Samples = (New-Object 'System.Collections.Generic.List[int]')
                        Errors  = 0
                    }
                    $byLabel[$label] = $bucket
                }
                $bucket.Samples.Add($elapsed)
                if (-not $success) { $bucket.Errors++ }
            }
        }
        finally { $reader.Dispose() }
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
        $merged.median_ms        = Get-Pct $sorted 50
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
    # Fall back to Locust's pre-aggregated stats CSV pattern.
    $candidates = @("*_stats.csv", "stats.csv", "results.csv", "clientResults*.csv")
    $statsFiles = @()
    foreach ($pattern in $candidates) {
        $found = @(Get-ChildItem -Path $ResultsDir -Recurse -Filter $pattern -File -ErrorAction SilentlyContinue)
        if ($found.Count -gt 0) {
            $statsFiles = $found
            break
        }
    }

    if ($statsFiles.Count -gt 0) {
        Write-Host "Parsing $($statsFiles.Count) Locust stats file(s):"
        $statsFiles | ForEach-Object { Write-Host "  - $($_.FullName)" }
        $metadata.parse_status = "ok"

        # Multi-engine merge: count-weighted average per metric.
        $byName = @{}
        foreach ($file in $statsFiles) {
            $stats = Import-Csv $file.FullName
            foreach ($row in $stats) {
                $name = $row.Name
                if ([string]::IsNullOrWhiteSpace($name) -or $name -eq 'Aggregated') { continue }
                if (-not $byName.ContainsKey($name)) { $byName[$name] = @() }
                $byName[$name] += $row
            }
        }

        foreach ($name in $byName.Keys) {
            $engineRows = $byName[$name]
            $totalReq  = 0
            $totalFail = 0
            $weighted  = @{ avg = 0.0; median = 0.0; p50 = 0.0; p90 = 0.0; p95 = 0.0; p99 = 0.0 }
            $rps       = 0.0
            $minVal    = [double]::PositiveInfinity
            $maxVal    = 0.0

            foreach ($r in $engineRows) {
                $reqCount = [int]($r.'Request Count' ?? 0)
                $totalReq  += $reqCount
                $totalFail += [int]($r.'Failure Count' ?? 0)

                $weighted.avg    += [double]($r.'Average Response Time' ?? 0) * $reqCount
                $weighted.median += [double]($r.'Median Response Time' ?? 0) * $reqCount
                $weighted.p50    += [double]($r.'50%' ?? 0) * $reqCount
                $weighted.p90    += [double]($r.'90%' ?? 0) * $reqCount
                $weighted.p95    += [double]($r.'95%' ?? 0) * $reqCount
                $weighted.p99    += [double]($r.'99%' ?? 0) * $reqCount
                $rps             += [double]($r.'Requests/s' ?? 0)

                $rMin = [double]($r.'Min Response Time' ?? 0)
                $rMax = [double]($r.'Max Response Time' ?? 0)
                if ($rMin -gt 0 -and $rMin -lt $minVal) { $minVal = $rMin }
                if ($rMax -gt $maxVal) { $maxVal = $rMax }
            }
            if ($minVal -eq [double]::PositiveInfinity) { $minVal = 0 }

            $errorRate = if ($totalReq -gt 0) { [math]::Round($totalFail / $totalReq, 4) } else { 0 }
            $div       = if ($totalReq -gt 0) { [double]$totalReq } else { 1.0 }

            $merged = [ordered]@{}
            foreach ($k in $metadata.Keys) { $merged[$k] = $metadata[$k] }
            $merged.scenario_name    = $name
            $merged.request_type     = $engineRows[0].Type
            $merged.request_count    = $totalReq
            $merged.failure_count    = $totalFail
            $merged.error_rate       = $errorRate
            $merged.avg_ms           = [math]::Round($weighted.avg / $div, 2)
            $merged.median_ms        = [math]::Round($weighted.median / $div, 2)
            $merged.p50_ms           = [math]::Round($weighted.p50 / $div, 2)
            $merged.p90_ms           = [math]::Round($weighted.p90 / $div, 2)
            $merged.p95_ms           = [math]::Round($weighted.p95 / $div, 2)
            $merged.p99_ms           = [math]::Round($weighted.p99 / $div, 2)
            $merged.min_ms           = $minVal
            $merged.max_ms           = $maxVal
            $merged.requests_per_sec = [math]::Round($rps, 2)
            $merged.engine_count     = $engineRows.Count
            $rows += [pscustomobject]$merged
        }
        Write-Host "Parsed $($rows.Count) sampler row(s) merged across $($statsFiles.Count) stats file(s)."
    }
    else {
        Write-Warning "No engine_results.csv or Locust stats CSV found under '$ResultsDir' - emitting metadata-only record."
        $metadata.parse_status = "no_metrics"
    }
}

# Always emit at least the metadata so the run is searchable. Downstream queries
# can filter on parse_status to distinguish real metric rows from placeholder rows.
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
# Write the summary OUTSIDE $ResultsDir so the upload-batch below (which uploads
# everything in $ResultsDir to /raw) doesn't end up duplicating it under raw/.
$summaryFile = Join-Path (Split-Path -Parent $ResultsDir) "summary.ndjson"

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
