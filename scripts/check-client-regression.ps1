#requires -Version 7.3

# Client-measurement regression gate. Reads client summary.ndjson rows from
# history storage (the 'client/{major}/' prefix), takes the latest run per
# (version × tier × metric) cell as candidate, compares its median against the
# median-of-last-N baseline. The baseline is like-for-like: only earlier runs
# on the candidate's App Service SKU, pool DTU cap and seeder preset.
#
# With -RunId (the pipeline passes its build id) only that run is judged, and
# a result the run should have produced but did not is reported as MISSING: a
# metric whose every repetition failed writes no row, and without this the gate
# would grade the previous run's row and say "ok". A candidate built on fewer
# repetitions than its baseline runs is reported as INCOMPLETE for the same
# reason - a median over the three repetitions that did not time out is not a
# result. Both fail the gate where a regression would. Mirrors check-regression.ps1's philosophy: report-only
# until >= MinBaselineRuns accrue, then fails (unless -NoFailOnRegression) so it can
# gate the pipeline.

[CmdletBinding()]
param(
    # Filters on the row's `scenario` field. The client blob prefix has no
    # scenario segment, so this is the only thing separating them. Empty = all.
    [string]$Scenario,
    [int]$Major,
    [string]$HistoryResourceGroup,
    [string]$StorageAccountName,
    [string]$ContainerName,
    [string]$OutputPath,
    [double]$MedianThreshold = 0.10,
    [int]$MinBaselineRuns = 3,
    [int]$BaselineWindow = 5,
    [switch]$NoFailOnRegression,
    [switch]$DotSourceForTest,

    # The run to judge (the pipeline's build id, which publish-client-results.ps1
    # writes as run_id). Empty = judge the latest row of every cell, as before.
    [string]$RunId,
    # Repetitions a complete result has. 0 = take it from the baseline runs.
    [int]$ExpectedReps = 0,

    # Optional LA target for ClientMeasurement_CL, mirroring check-regression.ps1.
    # Empty (default) skips posting.
    [string]$LogAnalyticsDceUri,
    [string]$LogAnalyticsDcrImmutableId,
    [string]$LogAnalyticsClientStreamName
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

. "$PSScriptRoot/_helpers.ps1"
. "$PSScriptRoot/_history-helpers.ps1"

# Pure decision function — unit-tested. A metric regresses when it has enough
# baseline runs AND the candidate median exceeds baseline-median x (1+threshold).
function Test-ClientRegression {
    param(
        [Parameter(Mandatory)] [double]$CandidateMedian,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [double[]]$BaselineMedians,
        [double]$Threshold = 0.10,
        [int]$MinBaselineRuns = 3
    )
    if ($BaselineMedians.Count -lt $MinBaselineRuns) {
        return [pscustomobject]@{ Insufficient = $true; Regressed = $false; BaselineMedian = $null }
    }
    $baseMedian = Get-Median ([double[]]$BaselineMedians)
    $regressed = $CandidateMedian -gt ($baseMedian * (1 + $Threshold))
    return [pscustomobject]@{ Insufficient = $false; Regressed = $regressed; BaselineMedian = $baseMedian }
}

# The earlier runs a candidate may be compared with: same App Service SKU, pool
# DTU cap and seeder preset, newest $Window of them. $Ordered is oldest first
# and ends with the candidate. A run on an overridden SKU is a different
# machine, not a baseline for this one.
function Select-ClientBaseline {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Ordered,
        [int]$Window = 5
    )
    if ($Ordered.Count -lt 2) { return [pscustomobject]@{ Rows = @(); Excluded = 0 } }
    $candidate = $Ordered[-1]
    $earlier = @($Ordered[0..($Ordered.Count - 2)])
    $same = @($earlier | Where-Object {
        [string]$_.app_service_sku -eq [string]$candidate.app_service_sku -and
        [string]$_.pool_dtu_max -eq [string]$candidate.pool_dtu_max -and
        [string]$_.seeder_preset -eq [string]$candidate.seeder_preset
    })
    [pscustomobject]@{ Rows = @($same | Select-Object -Last $Window); Excluded = $earlier.Count - $same.Count }
}

# How many repetitions a complete result has, and whether the candidate has
# them. Expected comes from -ExpectedReps, else from the most any baseline run
# had. $null Expected = nothing to judge against.
function Test-ClientComplete {
    param(
        [AllowNull()] $CandidateCount,
        [AllowEmptyCollection()] [object[]]$BaselineRows = @(),
        [int]$ExpectedReps = 0
    )
    $have = ConvertTo-IntOrNull ([string]$CandidateCount)
    $expected = if ($ExpectedReps -gt 0) { $ExpectedReps } else {
        $counts = @($BaselineRows | ForEach-Object { ConvertTo-IntOrNull ([string]$_.count) } | Where-Object { $null -ne $_ })
        if ($counts.Count) { ($counts | Measure-Object -Maximum).Maximum } else { $null }
    }
    $complete = ($null -eq $expected) -or ($null -eq $have) -or ($have -ge $expected)
    [pscustomobject]@{ Complete = $complete; Have = $have; Expected = $expected }
}

if ($DotSourceForTest) { return }

# $Major has no [Parameter(Mandatory)] (matches this script's other "real" run
# params, left optional so -DotSourceForTest doesn't need to supply them) - but
# an omitted/zero value must fail loudly here, not silently build a
# 'client/0/' blob prefix that matches nothing and reports a false "no client
# runs found" pass.
if ($Major -le 0) {
    Write-Host "##vso[task.logissue type=error]check-client-regression: -Major must be a positive Umbraco major version, got '$Major'."
    exit 1
}

# Get-HistoryCells can't be reused: client rows use `metric` + the `client/`
# prefix (it filters scenario_name and the `{scenario}/` prefix).
$prefix = "client/$Major/"
$storageKey = Get-StorageAccountKey -StorageAccountName $StorageAccountName -ResourceGroupName $HistoryResourceGroup

Write-Host "Listing client summary blobs under $prefix..."
$listJson = az storage blob list `
    --account-name $StorageAccountName --account-key $storageKey `
    --container-name $ContainerName --prefix $prefix `
    --num-results '*' `
    --query "[?ends_with(name, 'summary.ndjson')].name" -o json
$blobNames = @($listJson | ConvertFrom-Json)

# Group rows by (version × tier × metric); each cell is a time-ordered list of rows.
$cells = @{}
foreach ($blob in $blobNames) {
    $tmp = New-TemporaryFile
    az storage blob download --account-name $StorageAccountName --account-key $storageKey `
        --container-name $ContainerName --name $blob --file $tmp.FullName --no-progress | Out-Null
    $lines = Get-Content -Path $tmp.FullName
    Remove-Item -LiteralPath $tmp.FullName -Force -ErrorAction SilentlyContinue
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $row = $line | ConvertFrom-Json } catch { continue }
        if (-not $row.metric) { continue }
        # Rows predating the scenario field are treated as Default.
        if ($Scenario) {
            $rowScenario = if ($row.scenario) { [string]$row.scenario } else { 'Default' }
            if ($rowScenario -ne $Scenario) { continue }
        }
        $cellKey = "$($row.umbraco_version)__$($row.infra_tier)__$($row.metric)"
        if (-not $cells.ContainsKey($cellKey)) { $cells[$cellKey] = [System.Collections.Generic.List[object]]::new() }
        $cells[$cellKey].Add($row)
    }
}

$report = New-Object System.Text.StringBuilder
[void]$report.AppendLine("# Client measurement regression report`n")
[void]$report.AppendLine("Source: ``$prefix``$(if ($Scenario) { " filtered to scenario '$Scenario'" } else { " (all scenarios)" })`n")
$regressedAny = $false
$incompleteAny = $false

# What this run measured, as "version__tier". A cell of one of these with no
# row from this run is a metric the run failed to produce.
$runVersionTiers = [System.Collections.Generic.HashSet[string]]::new()
if ($RunId) {
    foreach ($list in $cells.Values) {
        foreach ($row in $list) {
            if ([string]$row.run_id -eq $RunId) { [void]$runVersionTiers.Add("$($row.umbraco_version)__$($row.infra_tier)") }
        }
    }
    if ($runVersionTiers.Count -eq 0) {
        $incompleteAny = $true
        [void]$report.AppendLine("- **MISSING: run $RunId published no client results at all.** Every measurement failed, or the publish step did not run.")
    }
}
if ($cells.Count -eq 0) { [void]$report.AppendLine("No client runs found under $prefix$(if ($Scenario) { " for scenario '$Scenario'" }).") }

# Per-cell verdict + candidate row, keyed by cellKey — used below to build the
# Log Analytics rows (one per run, aggregated across that run's metric cells).
$cellVerdicts = @{}

foreach ($cellKey in ($cells.Keys | Sort-Object)) {
    # Order chronologically by parsed datetime, not string compare: rows written
    # before TimeGenerated was normalized to ISO-8601 use a different format and
    # would mis-sort lexically, picking the wrong candidate/baseline. Unparseable
    # timestamps sort first (treated as oldest) rather than throwing.
    $ordered = @($cells[$cellKey] | Sort-Object {
        try { [datetime]::Parse([string]$_.TimeGenerated, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal) }
        catch { [datetime]::MinValue }
    })
    if ($RunId) {
        $mine = @($ordered | Where-Object { [string]$_.run_id -eq $RunId })
        if ($mine.Count -eq 0) {
            $versionTier = ($cellKey -split '__', 3)[0..1] -join '__'
            if ($runVersionTiers.Contains($versionTier)) {
                $incompleteAny = $true
                [void]$report.AppendLine("- **${cellKey}: MISSING** - run $RunId has no result for this metric (every repetition failed)")
            }
            continue   # another run's cell: not this run's to judge
        }
        # Judge this run's row against what came before it.
        $ordered = @($ordered[0..([array]::IndexOf($ordered, $mine[-1]))])
    }
    $candidate = $ordered[-1]
    $baseline = Select-ClientBaseline -Ordered $ordered -Window $BaselineWindow
    $baselineRows = @($baseline.Rows)
    $completeness = Test-ClientComplete -CandidateCount $candidate.count -BaselineRows $baselineRows -ExpectedReps $ExpectedReps
    if (-not $completeness.Complete) {
        $incompleteAny = $true
        [void]$report.AppendLine("- **${cellKey}: INCOMPLETE** - $($completeness.Have) of $($completeness.Expected) repetitions succeeded; the median below rests on those only")
    }
    if ($baselineRows.Count -eq 0) {
        $why = if ($baseline.Excluded -gt 0) { "no earlier run on the same SKU, DTU cap and seeder preset; $($baseline.Excluded) on another setup left out" } else { '1 run' }
        [void]$report.AppendLine("- ${cellKey}: insufficient baseline ($why)")
        $cellVerdicts[$cellKey] = [pscustomobject]@{ Candidate = $candidate; Regressed = $false; Insufficient = $true }
        continue
    }
    # Blank/unparseable median_ms -> $null (never 0). A 0 would read as "faster",
    # masking a regression on the candidate side and dragging the baseline median
    # down on the other. Candidate with no valid median can't be judged -> skip.
    $candMedian = ConvertTo-DoubleOrNull ([string]$candidate.median_ms)
    if ($null -eq $candMedian) {
        [void]$report.AppendLine("- ${cellKey}: skipped (candidate median missing/unparseable)")
        $cellVerdicts[$cellKey] = [pscustomobject]@{ Candidate = $candidate; Regressed = $false; Insufficient = $true }
        continue
    }
    $baselineMedians = [double[]]@($baselineRows | ForEach-Object { ConvertTo-DoubleOrNull ([string]$_.median_ms) } | Where-Object { $null -ne $_ })
    $verdict = Test-ClientRegression -CandidateMedian $candMedian `
        -BaselineMedians $baselineMedians -Threshold $MedianThreshold -MinBaselineRuns $MinBaselineRuns
    $cellVerdicts[$cellKey] = [pscustomobject]@{ Candidate = $candidate; Regressed = $verdict.Regressed; Insufficient = $verdict.Insufficient }
    if ($verdict.Insufficient) {
        [void]$report.AppendLine("- ${cellKey}: insufficient baseline ($($baselineMedians.Count) < $MinBaselineRuns runs)")
    } elseif ($verdict.Regressed) {
        $regressedAny = $true
        [void]$report.AppendLine("- **${cellKey}: REGRESSED** candidate $([math]::Round($candMedian))ms > baseline-median $([math]::Round($verdict.BaselineMedian))ms x $(1 + $MedianThreshold)")
    } else {
        [void]$report.AppendLine("- ${cellKey}: ok ($([math]::Round($candMedian))ms vs $([math]::Round($verdict.BaselineMedian))ms)")
    }
}

$reportText = $report.ToString()
if ($OutputPath) { $reportText | Out-File -FilePath $OutputPath -Encoding utf8 }
Write-Host $reportText

# Post regression-check status to ClientMeasurement_CL, mirroring
# check-regression.ps1. Failure here warns and continues - the build
# artifact remains authoritative.
if ($LogAnalyticsDceUri -and $LogAnalyticsDcrImmutableId -and $LogAnalyticsClientStreamName) {
    $statusByGroup = @{}   # key: run_id|scenario|version|tier
    foreach ($cellKey in $cellVerdicts.Keys) {
        $v         = $cellVerdicts[$cellKey]
        $candidate = $v.Candidate
        $parts     = $cellKey -split '__', 3
        $version   = $parts[0]
        $tier      = $parts[1]
        $metric    = $parts[2]

        $groupKey = "$($candidate.run_id)|$($candidate.scenario)|$version|$tier"
        if (-not $statusByGroup.ContainsKey($groupKey)) {
            $statusByGroup[$groupKey] = [pscustomobject]@{
                run_id             = $candidate.run_id
                scenario           = $candidate.scenario
                umbraco_version    = $version
                infra_tier         = $tier
                commit             = $candidate.commit
                branch             = $candidate.branch
                app_service_sku    = $candidate.app_service_sku
                pool_dtu_max       = $candidate.pool_dtu_max
                seeder_preset      = $candidate.seeder_preset
                regressed_metrics  = New-Object System.Collections.Generic.List[string]
                insufficient_count = 0
                checked_count      = 0
            }
        }
        $g = $statusByGroup[$groupKey]
        $g.checked_count++
        if ($v.Regressed)     { $g.regressed_metrics.Add($metric) }
        if ($v.Insufficient)  { $g.insufficient_count++ }
    }

    if ($statusByGroup.Count -gt 0) {
        $now = (Get-Date).ToUniversalTime().ToString("o")
        $rows = foreach ($g in $statusByGroup.Values) {
            $regressedList = ($g.regressed_metrics -join ',')
            $verdict =
                if ($g.regressed_metrics.Count -gt 0) { 'regress' }
                elseif ($g.insufficient_count -eq $g.checked_count) { 'insufficient' }
                else { 'pass' }
            [pscustomobject]@{
                TimeGenerated     = $now
                run_id            = [string]$g.run_id
                scenario          = [string]$g.scenario
                umbraco_version   = [string]$g.umbraco_version
                infra_tier        = [string]$g.infra_tier
                commit            = [string]$g.commit
                branch            = [string]$g.branch
                app_service_sku   = [string]$g.app_service_sku
                pool_dtu_max      = $g.pool_dtu_max
                seeder_preset     = [string]$g.seeder_preset
                metric            = 'regression_check'
                regression_status = $verdict
                regressed_metrics = $regressedList
                regressed_count   = $g.regressed_metrics.Count
            }
        }

        Write-Host ""
        Write-Host "Posting $($rows.Count) regression-status row(s) to Log Analytics ($LogAnalyticsClientStreamName)"
        try {
            $token = az account get-access-token --resource https://monitor.azure.com --query accessToken -o tsv
            $body  = ConvertTo-Json -InputObject @($rows) -Depth 5 -Compress -AsArray
            $url   = "$LogAnalyticsDceUri/dataCollectionRules/$LogAnalyticsDcrImmutableId/streams/${LogAnalyticsClientStreamName}?api-version=2023-01-01"
            Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType "application/json" `
                -Headers @{ Authorization = "Bearer $token" } | Out-Null
            Write-Host "   ok"
        }
        catch {
            $msg = "Client regression-status ingestion failed: $($_.Exception.Message). Build artifact ($OutputPath) remains authoritative."
            Write-Warning $msg
            Write-Host "##vso[task.logissue type=warning]$msg"
        }
    }
}

if ($incompleteAny) {
    # A warning even in report-only mode: this is a broken measurement, not a
    # judgement about speed.
    Write-Host "##vso[task.logissue type=warning]Client measurement is missing or incomplete for this run - see the report."
}
if (($regressedAny -or $incompleteAny) -and -not $NoFailOnRegression) {
    Write-Host "##vso[task.logissue type=error]Client measurement regression detected, or the measurement is missing or incomplete."
    exit 1
}
exit 0
