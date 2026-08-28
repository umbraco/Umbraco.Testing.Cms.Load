#requires -Version 7.3

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
    [Parameter(Mandatory = $true)] [int]$PoolDtuMax,
    [Parameter(Mandatory = $true)] [string]$SeederPreset,
    [Parameter(Mandatory = $true)] [string]$Tier,
    [Parameter(Mandatory = $true)] [string]$Scenario,
    [Parameter(Mandatory = $true)] [int]$UserCount,
    [Parameter(Mandatory = $true)] [int]$SpawnRate,
    [Parameter(Mandatory = $true)] [int]$DurationSeconds,
    [Parameter(Mandatory = $true)] [string]$SkipWarmup,
    [Parameter(Mandatory = $true)] [string]$TestCaseId,

    # Effective VU ramp-up window in seconds (prepare-test-cases.ps1's resolved
    # rampTime - already defaults to UserCount when the queue-time value was 0).
    # Excluded from percentile/error/throughput stats: during ramp-up, load is
    # below target so those samples are systematically easier than steady-state.
    # LoadProfile == 'ramp' disables the exclusion - that profile's whole point
    # is the climb, there's no separate steady state to isolate it from.
    [Parameter(Mandatory = $true)] [int]$RampTimeSeconds,
    [Parameter(Mandatory = $true)] [string]$LoadProfile,

    # Server-side metric query window + resource IDs. Queried via Azure Monitor
    # and injected into row metadata alongside the client-side latencies.
    [Parameter(Mandatory = $true)] [string]$LoadTestStartTime,
    [Parameter(Mandatory = $true)] [string]$LoadTestEndTime,
    [Parameter(Mandatory = $true)] [string]$AppServiceResourceId,
    [Parameter(Mandatory = $true)] [string]$AppServicePlanResourceId,
    [Parameter(Mandatory = $true)] [string]$SqlDatabaseResourceId,

    # Seeder duration in seconds, captured by install-umbraco-cms-on-appservice.ps1
    # and surfaced via the load-test-job template. Optional — empty/blank means
    # the seeder didn't complete (Skipped, Failed, TimedOut, or pre-feature run);
    # the field is then omitted from the row instead of being written as 0.
    [string]$SeederDurationSeconds = "",

    # JMeter test plan stem (e.g. 'ViewHomePage', 'MemberLogin'). Empty for
    # frontend (Locust) runs and the single-.jmx legacy backoffice path. When
    # set, the publish step (a) suffixes the blob path with the .jmx stem so
    # parallel .jmx publishes in the same pipeline don't overwrite each other,
    # and (b) tags every LA row with jmeter_test_name so the dashboard can
    # separate per-.jmx samplers when (and if) the DCR column is added.
    [string]$JmeterTestName = "",

    # Optional Logs Ingestion API target. When DceUri + DcrImmutableId + the
    # SUMMARY stream name are provided, the script POSTs each summary row to
    # the Log Analytics custom table in addition to the blob upload (the
    # Workbook reads from there). Provisioned by ensure-monitoring-infra.ps1 —
    # that script prints all four values.
    [string]$LogAnalyticsDceUri,
    [string]$LogAnalyticsDcrImmutableId,
    [string]$LogAnalyticsStreamName,
    # When also set, per-minute Azure Monitor datapoints (plan CPU/memory, SQL
    # DTU/CPU/log-write/physical-reads, HTTP 4xx/5xx) are POSTed to a second LA
    # custom table (LoadTestSeries_CL) for the dashboard's per-run drill-down.
    # Empty (default) skips the series mirror but keeps the summary mirror.
    [string]$LogAnalyticsSeriesStreamName
)

$ErrorActionPreference = "Stop"

# Make native commands (az CLI) honour $ErrorActionPreference so a failed blob upload
# fails the publish step instead of silently exiting 0. Requires pwsh 7.3+.
$PSNativeCommandUseErrorActionPreference = $true

. "$PSScriptRoot/_helpers.ps1"

# $(System.PipelineStartTime) is space-separated ("2026-06-15 13:45:30+00:00");
# LA's Logs Ingestion API rejects that on a datetime column with a 400. Normalize
# once so run_started_at and the per-row TimeGenerated both ingest. (The blob date
# parse below tolerates ISO too.)
$RunStartedAt = ConvertTo-IsoUtc $RunStartedAt

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
    pool_dtu_max     = $PoolDtuMax
    seeder_preset    = $SeederPreset
    infra_tier       = $Tier
    # Null (rather than 0) when the seeder didn't complete (Skipped, Failed,
    # TimedOut, or pre-feature run) — KQL percentile/avg ignore nulls, so
    # Skipped/Failed runs don't drag the median toward 0. ConvertTo-DoubleOrNull
    # (_helpers) invariant-culture TryParses: empty/malformed (or a comma-decimal
    # agent locale) degrades to $null instead of throwing under -ErrorAction Stop
    # and killing the publish before any row is written.
    seeder_duration_seconds = ConvertTo-DoubleOrNull $SeederDurationSeconds
    scenario         = $Scenario
    user_count       = $UserCount
    spawn_rate       = $SpawnRate
    duration_seconds = $DurationSeconds
    # Schema name stays `cold_start` — it describes the test condition
    # (was warmup skipped, i.e. cold-start exercised). $SkipWarmup is the
    # procedural pipeline-side phrasing; both mean the same boolean.
    # Tolerant parse: the pipeline passes 'True'/'False', but any other/empty
    # value should degrade to $false, not hard-throw the whole publish before a
    # single row is emitted (which [bool]::Parse would do under -ErrorAction Stop).
    cold_start       = ($SkipWarmup -ieq 'true')
}

# Carry the .jmx stem on every row so future dashboard queries can split
# per-.jmx data. Stays empty for Locust runs — KQL `isnotempty()` filters
# pick out backoffice rows when needed.
if (-not [string]::IsNullOrWhiteSpace($JmeterTestName)) {
    $metadata.jmeter_test_name = $JmeterTestName
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
        [Parameter(Mandatory)] [string]$EndTime,
        # Optional prefix on returned series metric_name (e.g. 'plan' →
        # 'plan_CpuPercentage'). Summary keys still come back unprefixed so the
        # caller does its own `plan_*` prefixing of $metadata, matching prior
        # behaviour and the DCR column names on LoadTestSummary_CL.
        [string]$Prefix = '',
        # Aggregation to request from Azure Monitor. CPU/DTU are gauges → Average
        # (the default). Count metrics like Http5xx/Http4xx are only meaningful as
        # Total: their Average is a near-zero per-minute mean and is inconsistent
        # with the ALT appComponents config, which registers them as Total. Azure
        # Monitor names the per-point property after the aggregation, so we read
        # $_.$aggProp rather than a hardcoded .average.
        [ValidateSet('Average', 'Total', 'Maximum', 'Minimum', 'Count')]
        [string]$Aggregation = 'Average',
        # PT1M by default (SQL DTU/CPU and HTTP error counts publish at that
        # resolution). Pass '' to omit --interval and let Azure Monitor pick the
        # metric's native granularity instead - needed for metrics whose native
        # resolution is coarser than 1 minute (e.g. serverfarms CpuPercentage/
        # MemoryPercentage, confirmed live: requesting PT1M got 12 data-point
        # slots back with errorCode=Success but every one's 'average' null,
        # because none of the 1-minute buckets aligned with the metric's actual
        # sampling interval).
        [string]$Interval = 'PT1M'
    )
    $aggProp = $Aggregation.ToLowerInvariant()
    $summary = @{}
    $series  = New-Object System.Collections.Generic.List[object]
    try {
        $intervalArgs = if ($Interval) { @('--interval', $Interval) } else { @() }
        $json = az monitor metrics list `
            --resource $ResourceId `
            --metric ($Metrics -join ',') `
            --aggregation $Aggregation `
            --start-time $StartTime `
            --end-time $EndTime `
            @intervalArgs `
            -o json
        $data = $json | ConvertFrom-Json
        foreach ($metric in $data.value) {
            $name = $metric.name.value
            $prefixedName = if ($Prefix) { "${Prefix}_${name}" } else { $name }
            # Flatten across every timeseries entry, not just [0]. Azure Monitor
            # emits one timeseries per dimensioned instance — e.g. a P1v3 plan
            # with worker_count > 1, or a SQL DB with read replicas — and reading
            # only [0] under-samples by (N-1)/N. _avg is the mean across all
            # (instance × minute) points; _max is the peak load on any instance
            # at any minute (the saturation lens).
            $points = @($metric.timeseries | ForEach-Object { $_.data } |
                Where-Object { $null -ne $_.$aggProp })
            if ($points.Count -eq 0) {
                $summary["${name}_avg"] = $null
                $summary["${name}_max"] = $null
                # Surface as a warning too — AzMon returning success + zero
                # datapoints is the silent failure mode (e.g. VM hadn't started
                # emitting yet, wrong time window). Without this the column
                # just shows blank in the dashboard with no clue why.
                #
                # errorCode/errormessage are per-metric fields in AzMon's response
                # (distinct from an empty-but-successful result) - capturing them,
                # plus whether any raw timeseries/data entries exist at all, turns
                # a recurring "0 datapoints" into a diagnosable signal instead of a
                # repeated guess: errorCode != Success is an API-level problem, a
                # non-empty timeseries with 0 usable points is an aggregation-name
                # mismatch, and truly empty timeseries is the only case that still
                # looks like propagation lag.
                $rawTimeseriesCount = @($metric.timeseries).Count
                $rawDataPointCount  = @($metric.timeseries | ForEach-Object { $_.data } | Where-Object { $_ }).Count
                $errorCode = if ($metric.errorCode) { [string]$metric.errorCode } else { "n/a" }
                $errorDetail = if ($metric.errormessage) { " errormessage=`"$($metric.errormessage)`"" } else { "" }
                $msg = "Azure Monitor returned 0 datapoints for $name on $ResourceId over [$StartTime, $EndTime] - column will be null. errorCode=$errorCode$errorDetail timeseries=$rawTimeseriesCount rawDataPoints=$rawDataPointCount (aggregation=$Aggregation)."
                Write-Warning $msg
                Write-Host "##vso[task.logissue type=warning]$msg"
                continue
            }
            # Per-minute points retained for LoadTestSeries_CL. The summary
            # scalars (avg/max) are still computed for LoadTestSummary_CL so
            # both views stay populated even on a series-ingest failure.
            foreach ($p in $points) {
                $series.Add([pscustomobject]@{
                    TimeGenerated = [string]$p.timeStamp
                    metric_name   = $prefixedName
                    value         = [double]$p.$aggProp
                })
            }
            $values = @($points | ForEach-Object { [double]$_.$aggProp })
            $summary["${name}_avg"] = [math]::Round((($values | Measure-Object -Average).Average), 2)
            $summary["${name}_max"] = [math]::Round((($values | Measure-Object -Maximum).Maximum), 2)
        }
    } catch {
        # Surface to BOTH the task log AND the AzDO summary panel — silent
        # Write-Warning blends into the log and a partial-metrics gap (e.g.
        # plan_* missing while sql_*/app_* populate) drifts unnoticed for
        # multiple runs.
        $msg = "Azure Monitor query failed for $ResourceId : $($_.Exception.Message)"
        Write-Warning $msg
        Write-Host "##vso[task.logissue type=warning]$msg"
    }
    return @{ Summary = $summary; Series = $series }
}

# Parse the load-test window into a length in seconds. Returns 0 if either
# timestamp is missing or unparseable — callers compare against a minimum
# threshold to decide whether the window is usable for Azure Monitor queries.
# Tolerant by design: an ALT fast-failure produces empty timestamps; we want
# the caller's "window unusable" branch, not a hard throw.
function Get-WindowSeconds {
    param(
        [Parameter(Mandatory)] [string]$StartTime,
        [Parameter(Mandatory)] [string]$EndTime
    )
    try {
        $start = [datetime]::Parse($StartTime, [System.Globalization.CultureInfo]::InvariantCulture)
        $end   = [datetime]::Parse($EndTime,   [System.Globalization.CultureInfo]::InvariantCulture)
        return ($end - $start).TotalSeconds
    } catch {
        Write-Verbose "Failed to parse load-test window: $($_.Exception.Message)"
        return 0
    }
}

# Logs Ingestion API mirror. Used for both happy-path rows and the early-exit
# no_results_dir case below; keeping it as a function avoids duplicating the
# token/POST/error-handling boilerplate in two places.
function Send-RowsToLogAnalytics {
    param([Parameter(Mandatory)] [object[]]$Rows)
    if (-not ($LogAnalyticsDceUri -and $LogAnalyticsDcrImmutableId -and $LogAnalyticsStreamName)) {
        return
    }
    Write-Host ""
    Write-Host "Posting $($Rows.Count) row(s) to Log Analytics ($LogAnalyticsStreamName)"
    try {
        $token = az account get-access-token --resource https://monitor.azure.com --query accessToken -o tsv
        # The DCR expects TimeGenerated on every row; carry the run start time so
        # all per-sampler rows of one run share a single point on the time axis.
        $ingestRows = $Rows | ForEach-Object {
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
        # $_.ErrorDetails.Message carries the API response body, which names the
        # rejected field (e.g. an invalid datetime) — the bare status line doesn't.
        $detail = if ($_.ErrorDetails.Message) { " Body: $($_.ErrorDetails.Message)" } else { "" }
        $msg = "Log Analytics ingestion failed: $($_.Exception.Message).$detail Blob upload (if any) remains the source of truth."
        Write-Warning $msg
        Write-Host "##vso[task.logissue type=warning]$msg"
    }
}

# Per-minute time-series sender. Posts one row per (metric × minute) to the
# companion LoadTestSeries_CL table for the workbook's per-run drill-down.
# Gated on $LogAnalyticsSeriesStreamName so the summary mirror can be enabled
# without forcing the series mirror (early adopters, ingestion-cost caution).
# Same defensive posture as Send-RowsToLogAnalytics: failure warns and continues;
# the summary scalars (plan_*/sql_*/app_* in LoadTestSummary_CL) remain
# authoritative for capacity verdicts.
function Send-SeriesToLogAnalytics {
    # AllowEmptyCollection because the window guard above legitimately produces
    # zero points when the test fast-failed — without this attribute,
    # PowerShell's strict array binding rejects empty arrays BEFORE the function
    # body's early-return can fire, crashing the publish step (Bug B from the
    # first end-to-end run, exposed when a downstream .jmx iteration had a
    # ~2-second unusable window after an ALT validation failure).
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Points)
    if (-not ($LogAnalyticsDceUri -and $LogAnalyticsDcrImmutableId -and $LogAnalyticsSeriesStreamName)) {
        return
    }
    if ($Points.Count -eq 0) { return }
    Write-Host ""
    Write-Host "Posting $($Points.Count) per-minute series row(s) to Log Analytics ($LogAnalyticsSeriesStreamName)"
    try {
        $token = az account get-access-token --resource https://monitor.azure.com --query accessToken -o tsv
        # Hydrate each point with run-level context. TimeGenerated comes from
        # the Azure Monitor datapoint timestamp (not the run start) so the
        # workbook's time-series chart renders true minute-by-minute.
        $rows = $Points | ForEach-Object {
            [pscustomobject]@{
                TimeGenerated     = [string]$_.TimeGenerated
                run_id            = [string]$BuildId
                scenario          = [string]$Scenario
                umbraco_version   = [string]$UmbracoVersion
                infra_tier        = [string]$Tier
                # Keeps the per-minute table queryable by .jmx for backoffice
                # runs. Empty string for Locust runs and pre-feature backoffice
                # rows; KQL `isnotempty()` separates them.
                jmeter_test_name  = [string]$JmeterTestName
                metric_name       = [string]$_.metric_name
                value             = [double]$_.value
            }
        }
        $body = ConvertTo-Json -InputObject @($rows) -Depth 5 -Compress -AsArray
        $url  = "$LogAnalyticsDceUri/dataCollectionRules/$LogAnalyticsDcrImmutableId/streams/${LogAnalyticsSeriesStreamName}?api-version=2023-01-01"
        Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType "application/json" `
            -Headers @{ Authorization = "Bearer $token" } | Out-Null
        Write-Host "   ok"
    }
    catch {
        $detail = if ($_.ErrorDetails.Message) { " Body: $($_.ErrorDetails.Message)" } else { "" }
        $msg = "Log Analytics series ingestion failed: $($_.Exception.Message).$detail Summary scalars (plan_*/sql_*/app_*) are still in LoadTestSummary_CL."
        Write-Warning $msg
        Write-Host "##vso[task.logissue type=warning]$msg"
    }
}

# Bail out if there's no results dir at all. Still emit a metadata-only row to
# Log Analytics so the run is visible in the Workbook (rather than vanishing
# entirely and leaving downstream regression-check comparing against stale
# baselines without anyone noticing).
if (-not (Test-Path $ResultsDir)) {
    Write-Warning "Results dir '$ResultsDir' not found - emitting metadata-only Log Analytics row and exiting."
    $metadata.parse_status = "no_results_dir"
    Send-RowsToLogAnalytics -Rows @([pscustomobject]$metadata)
    exit 0
}

# ALT emits engine{N}_results.csv (JMeter format) — raw per-request data, one
# row per HTTP call. Header: timeStamp, elapsed, label, responseCode,
# responseMessage, threadName, dataType, success, failureMessage, ...
# Multi-engine runs produce one CSV per engine; we aggregate across all of them.
# Get-Pct and Parse-JmeterCsv are provided by _helpers.ps1.

# Window guard. AzureLoadTest@1 has continueOnError: true; on a fast failure
# (engine provisioning, auth) the captured window is just seconds, and querying
# Azure Monitor over it yields null/near-zero metrics that pollute the Workbook
# trend lines. When the window is unusably short (or empty — start-capture step
# never ran), skip the metric query entirely so plan_/sql_/app_ fields stay
# absent from the row instead of present-but-null.
$windowSec    = Get-WindowSeconds -StartTime $LoadTestStartTime -EndTime $LoadTestEndTime
$minWindowSec = 30

# Initialised here so the post-loop Send-SeriesToLogAnalytics call always has
# something to enumerate, even when the window-guard branch skips the queries.
$seriesPoints = New-Object System.Collections.Generic.List[object]

Write-Host ""
if ($windowSec -ge $minWindowSec) {
    Write-Host "Querying Azure Monitor for server-side metrics over [$LoadTestStartTime, $LoadTestEndTime] ($([int]$windowSec)s)..."

    $planResult = Get-MetricSummary `
        -ResourceId $AppServicePlanResourceId `
        -Metrics @("CpuPercentage", "MemoryPercentage") `
        -StartTime $LoadTestStartTime -EndTime $LoadTestEndTime `
        -Prefix 'plan' `
        -Interval ''
    foreach ($k in $planResult.Summary.Keys) { $metadata["plan_$k"] = $planResult.Summary[$k] }
    foreach ($p in $planResult.Series) { $seriesPoints.Add($p) }

    $sqlResult = Get-MetricSummary `
        -ResourceId $SqlDatabaseResourceId `
        -Metrics @("dtu_consumption_percent", "cpu_percent", "log_write_percent", "physical_data_read_percent") `
        -StartTime $LoadTestStartTime -EndTime $LoadTestEndTime `
        -Prefix 'sql'
    foreach ($k in $sqlResult.Summary.Keys) { $metadata["sql_$k"] = $sqlResult.Summary[$k] }
    foreach ($p in $sqlResult.Series) { $seriesPoints.Add($p) }

    $appResult = Get-MetricSummary `
        -ResourceId $AppServiceResourceId `
        -Metrics @("Http5xx", "Http4xx") `
        -StartTime $LoadTestStartTime -EndTime $LoadTestEndTime `
        -Prefix 'app' `
        -Aggregation Total
    foreach ($k in $appResult.Summary.Keys) { $metadata["app_$k"] = $appResult.Summary[$k] }
    foreach ($p in $appResult.Series) { $seriesPoints.Add($p) }
}
else {
    Write-Warning "Test window unusable ($([int]$windowSec)s; start='$LoadTestStartTime', end='$LoadTestEndTime') - skipping Azure Monitor metric query. Most likely cause: AzureLoadTest@1 fast-failed (e.g. engine provisioning, auth)."
}

# ALT emits engine{N}_results.csv (JMeter format) — raw per-request data, one
# row per HTTP call. Header: timeStamp, elapsed, label, responseCode,
# responseMessage, threadName, dataType, success, failureMessage, ...
# Multi-engine runs produce one CSV per engine; we aggregate across all of them.
# Get-Pct and Parse-JmeterCsv are provided by _helpers.ps1.

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

    # Backoffice (JMeter) runs always set $JmeterTestName (the .jmx stem),
    # while frontend (Locust) runs leave it empty. Use that as the signal to
    # flip Parse-JmeterCsv into TC-only mode so the workbook shows the
    # "01. <step>" transaction-controller rows instead of the dozens of
    # underlying GET/POST sampler rows per .jmx.
    $onlyTC = -not [string]::IsNullOrWhiteSpace($JmeterTestName)

    # Ramp-up cutoff (epoch ms), passed to Parse-JmeterCsv so ramp-window samples
    # are excluded from every stat. Anchored to the engines' OWN first request
    # timestamp (discovered via an unfiltered first pass below), not the
    # pipeline's LoadTestStartTime - AzureLoadTest@1 still has to provision
    # engines and dispatch the test plan after that's captured, and that
    # dispatch lag (tens of seconds, plausibly the same order as the ramp
    # window itself) would otherwise misalign the cutoff against when the
    # engine's own ramp actually started. Skipped for the 'ramp' profile (the
    # climb is the point) and left disabled (0) if no engine file has a single
    # usable timestamp - same tolerant posture as Get-WindowSeconds: no
    # reference point means "can't judge the window", not "block publish".
    $rampCutoffMs = 0
    if ($LoadProfile -ne 'ramp') {
        $discoveryMinTs = [long]::MaxValue
        foreach ($file in $engineFiles) {
            try {
                $probe = Parse-JmeterCsv -Path $file.FullName -OnlyTransactionControllers:$onlyTC
            } catch {
                continue  # Surfaced properly by the real parse pass below.
            }
            if ($null -ne $probe.MinTimestamp -and $probe.MinTimestamp -lt $discoveryMinTs) { $discoveryMinTs = $probe.MinTimestamp }
        }
        if ($discoveryMinTs -ne [long]::MaxValue) {
            $rampCutoffMs = $discoveryMinTs + ([long]$RampTimeSeconds * 1000)
        }
    }

    if ($rampCutoffMs -gt 0) {
        Write-Host "Excluding the first ${RampTimeSeconds}s (VU ramp-up, anchored to the engines' first request) from latency/error/throughput stats."
    } elseif ($LoadProfile -eq 'ramp') {
        Write-Host "LoadProfile=ramp - not excluding any ramp-up window (the climb is what this profile measures)."
    } else {
        Write-Warning "No usable sample timestamps in any engine file - can't anchor the ramp-up cutoff, including all samples."
    }

    # Parse each engine CSV via the shared parser (Parse-JmeterCsv in _helpers.ps1);
    # merge the per-label buckets across engines. Single-engine runs trivially
    # become one parse call; multi-engine runs concatenate samples per label.
    $byLabel = @{}
    # Sample window across every engine file, for the throughput denominator.
    $spanMinTs = [long]::MaxValue
    $spanMaxTs = [long]::MinValue
    foreach ($file in $engineFiles) {
        # One unreadable/corrupt engine file (e.g. truncated mid-write) must not
        # abort the whole publish - skip it and keep the other engines' data.
        try {
            $parsed = Parse-JmeterCsv -Path $file.FullName -OnlyTransactionControllers:$onlyTC -RampCutoffMs $rampCutoffMs
        } catch {
            Write-Warning "Couldn't parse $($file.FullName): $($_.Exception.Message) - skipping this file."
            continue
        }
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
        if ($null -ne $parsed.MinTimestamp -and $parsed.MinTimestamp -lt $spanMinTs) { $spanMinTs = $parsed.MinTimestamp }
        if ($null -ne $parsed.MaxTimestamp -and $parsed.MaxTimestamp -gt $spanMaxTs) { $spanMaxTs = $parsed.MaxTimestamp }
    }

    # Throughput denominator: the span the samples cover, not the configured
    # duration - they diverge when ALT autoStops early or the run fast-fails,
    # and the configured value then understates the rate. Floored at 1s; falls
    # back to $DurationSeconds when no timestamp parsed. timeStamp is the sample
    # START, so the last sample's own latency is deliberately not added.
    # > 0 (not >= 1s) is the real "did we get data" test - the old 1s floor
    # discarded genuinely valid short spans (e.g. a fast smoke run).
    $observedSpanSec = 0.0
    $haveSpan = ($spanMaxTs -ge $spanMinTs -and $spanMinTs -ne [long]::MaxValue)
    if ($haveSpan) {
        $observedSpanSec = [math]::Round(($spanMaxTs - $spanMinTs) / 1000.0, 3)
    }
    $testDurationSec = if ($haveSpan -and $observedSpanSec -gt 0) { $observedSpanSec } else { [double]$DurationSeconds }
    if ($haveSpan -and $observedSpanSec -gt 0) {
        Write-Host "Throughput window: observed sample span $observedSpanSec s (configured duration ${DurationSeconds}s)."
    } else {
        Write-Warning "No usable sample timestamps - falling back to the configured duration (${DurationSeconds}s) for requests_per_sec."
    }

    foreach ($label in $byLabel.Keys) {
        $bucket = $byLabel[$label]
        $sorted = [System.Collections.Generic.List[int]]::new($bucket.Samples)
        $sorted.Sort()

        $reqCount  = $sorted.Count
        $failCount = $bucket.Errors
        $errorRate = if ($reqCount -gt 0) { [math]::Round($failCount / $reqCount, 4) } else { 0 }
        $rps       = if ($testDurationSec -gt 0 -and $reqCount -gt 0) { [math]::Round($reqCount / $testDurationSec, 2) } else { 0 }
        # Round to match the DCR's "real" type on this column; the underlying
        # JMeter samples are int ms but the mean across them is fractional.
        $avg       = if ($reqCount -gt 0) { [math]::Round((($sorted | Measure-Object -Average).Average), 2) } else { 0 }

        $merged = [ordered]@{}
        foreach ($k in $metadata.Keys) { $merged[$k] = $metadata[$k] }
        # Backoffice runs iterate multiple .jmx files whose Transaction
        # Controllers share labels ("01. Open backoffice", "02. Login", ...).
        # The workbook groups the sampler dimension on scenario_name and does
        # not read jmeter_test_name, so without a discriminator the same-named
        # TCs from different .jmx merge into one cell. Prefix the .jmx stem for
        # backoffice (JmeterTestName set) to keep them distinct; frontend
        # (Locust) rows keep the bare label.
        $merged.scenario_name    = if ([string]::IsNullOrWhiteSpace($JmeterTestName)) { $label } else { "$JmeterTestName / $label" }
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

# AdjustToUniversal - plain Parse would otherwise read this already-UTC
# string as the agent's local time, shifting $datePart on a non-UTC agent.
$pipelineStarted = [DateTime]::Parse($RunStartedAt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
$datePart        = $pipelineStarted.ToString("yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)

# Major = first dot-segment (e.g. '17' for '17.0.0' and '17.0.0-rc.1').
$majorVersion = (Get-UmbracoMajor $UmbracoVersion).ToString()

# When backoffice mode iterates multiple .jmx files in one pipeline run, each
# .jmx must land at its own blob path or iteration N overwrites iteration N-1's
# raw/ artifacts. Frontend (Locust) runs keep the legacy prefix shape unchanged.
$blobPrefix = "$Scenario/$majorVersion/$UmbracoVersion/$Tier/${datePart}_$BuildId"
if (-not [string]::IsNullOrWhiteSpace($JmeterTestName)) {
    $blobPrefix = "$blobPrefix/$JmeterTestName"
}
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

# Trim redundant artifacts before the raw upload (the history container has no
# expiry beyond the lifecycle tier, so anything uploaded here is kept forever):
#  - *-extracted working dirs: unpacked only to scan engine_results.csv; their
#    contents already live inside results.zip, so keeping them doubles every CSV.
#  - report.zip: ALT's generated HTML report. Nothing in this repo consumes it
#    (the parser reads results.zip) and the same report is in the Azure portal
#    run view, so archiving it here is pure bloat.
# results.zip is deliberately kept — it carries the raw per-request data that
# re-analysis may need beyond what summary.ndjson surfaces.
Get-ChildItem -Path $ResultsDir -Recurse -Directory -Filter '*-extracted' -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $ResultsDir -Recurse -File -Filter 'report.zip' -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

# Raw artifacts kept for analyses that need fields the summary doesn't surface.
az storage blob upload-batch `
    --account-name $StorageAccountName --account-key $storageKey `
    --destination $ContainerName `
    --destination-path "$blobPrefix/raw" `
    --source $ResultsDir `
    --pattern "*" `
    --overwrite | Out-Null

Write-Host "Published $($rows.Count) record(s) + raw artifacts."

# Mirror to Log Analytics. Same defensive posture as the Azure Monitor metric
# query above — failure warns and continues; the blob upload is the source of
# truth and recoverable via backfill-monitoring.ps1.
Send-RowsToLogAnalytics -Rows $rows
# Per-minute series mirror — additive to the summary, populates the table
# the workbook's per-run drill-down reads. Empty when the test window was
# unusable above (no datapoints were retrieved).
Send-SeriesToLogAnalytics -Points $seriesPoints
