#requires -Version 7.3

# Compare two Locust runs and emit a markdown report with per-sampler deltas.
# Two modes:
#
# History mode (preferred for "did this regress?" questions - pulls aggregated
# per-sampler stats straight from history storage, no manual artifact download):
#
#   # version vs version on a fixed tier
#   ./scripts/compare-runs.ps1 -Scenario Default -Tier Standard `
#       -BaselineVersion 17.0.0 -CandidateVersion 17.0.1 `
#       -HistoryResourceGroup umbraco-loadtest-history-rg `
#       -StorageAccountName loadtesthistory -ContainerName loadtest-history
#
#   # tier vs tier on a fixed version
#   ./scripts/compare-runs.ps1 -Scenario Default -Version 17.0.0 `
#       -BaselineTier Starter -CandidateTier Pro `
#       -HistoryResourceGroup umbraco-loadtest-history-rg `
#       -StorageAccountName loadtesthistory -ContainerName loadtest-history
#
#   Aggregate mode: 'latest' (default) takes the most recent run per cell;
#   'median5' takes the median across the last 5 runs (more stable on noisy tails).
#
# CSV mode (for local Locust runs or offline analysis where history isn't
# available - same shape as the original script):
#
#   ./scripts/compare-runs.ps1 -BaselinePath ./run1/engine1_results.csv `
#                              -CandidatePath ./run2/engine1_results.csv `
#                              -BaselineLabel "17.0.0" -CandidateLabel "17.0.1"
#
# CSV is JMeter format (what Azure Load Testing emits):
#   timeStamp,elapsed,label,responseCode,responseMessage,threadName,dataType,success,...

[CmdletBinding()]
param (
    # CSV mode (provide both paths)
    [string]$BaselinePath,
    [string]$CandidatePath,

    # History mode (provide -Scenario + storage + EITHER version-vs-version OR tier-vs-tier)
    [string]$Scenario,
    [string]$HistoryResourceGroup,
    [string]$StorageAccountName,
    [string]$ContainerName,
    [string]$Major,

    # version-vs-version: -Tier shared, -BaselineVersion + -CandidateVersion vary
    [string]$Tier,
    [string]$BaselineVersion,
    [string]$CandidateVersion,

    # tier-vs-tier: -Version shared, -BaselineTier + -CandidateTier vary
    [string]$Version,
    [string]$BaselineTier,
    [string]$CandidateTier,

    [ValidateSet('latest', 'median5')] [string]$Aggregate = 'latest',

    # Common
    [string]$BaselineLabel,
    [string]$CandidateLabel,
    [string]$OutputPath,
    [int]$SignificantDeltaPercent = 10
)

$ErrorActionPreference = "Stop"

# Native commands (az CLI in history mode) honour $ErrorActionPreference.
$PSNativeCommandUseErrorActionPreference = $true

. "$PSScriptRoot/_helpers.ps1"

# --- Mode detection + validation ---

$isCsvMode     = $BaselinePath -or $CandidatePath
$isHistoryMode = $Scenario -or $HistoryResourceGroup -or $StorageAccountName -or $ContainerName

if ($isCsvMode -and $isHistoryMode) {
    Write-PipelineError "Specify EITHER CSV mode (-BaselinePath/-CandidatePath) OR history mode (-Scenario/-StorageAccountName/-ContainerName) - not both."
}
if (-not ($isCsvMode -or $isHistoryMode)) {
    Write-PipelineError "Specify either CSV mode (-BaselinePath + -CandidatePath) or history mode (-Scenario + -StorageAccountName + -ContainerName + version/tier coordinates)."
}

if ($isCsvMode) {
    if (-not ($BaselinePath -and $CandidatePath)) {
        Write-PipelineError "CSV mode requires both -BaselinePath and -CandidatePath."
    }
    if (-not (Test-Path $BaselinePath))  { Write-PipelineError "Baseline CSV not found: $BaselinePath" }
    if (-not (Test-Path $CandidatePath)) { Write-PipelineError "Candidate CSV not found: $CandidatePath" }
}

if ($isHistoryMode) {
    if (-not ($Scenario -and $StorageAccountName -and $ContainerName)) {
        Write-PipelineError "History mode requires -Scenario, -StorageAccountName, and -ContainerName."
    }
    $isVersionPair = $BaselineVersion -and $CandidateVersion
    $isTierPair    = $BaselineTier -and $CandidateTier
    if ($isVersionPair -and $isTierPair) {
        Write-PipelineError "History mode: choose ONE comparison axis - version-vs-version (with shared -Tier) OR tier-vs-tier (with shared -Version)."
    }
    if (-not ($isVersionPair -or $isTierPair)) {
        Write-PipelineError "History mode: provide either version-vs-version (-Tier + -BaselineVersion + -CandidateVersion) or tier-vs-tier (-Version + -BaselineTier + -CandidateTier)."
    }
    if ($isVersionPair -and -not $Tier) {
        Write-PipelineError "Version-vs-version comparison requires -Tier (the shared tier)."
    }
    if ($isTierPair -and -not $Version) {
        Write-PipelineError "Tier-vs-tier comparison requires -Version (the shared version)."
    }
}

# --- CSV-mode stats: stream raw samples, compute true aggregate + per-label ---

function Get-RunStats {
    param ([string]$Path)

    # Parser is shared with publish-load-test-results.ps1 - see Parse-JmeterCsv
    # in _helpers.ps1. -BuildAggregate keeps the per-CSV all-samples list so we
    # can compute a true aggregate percentile (which history mode can't).
    $parsed = Parse-JmeterCsv -Path $Path -BuildAggregate

    function Get-Stats ($samples, $errors) {
        $sorted = ($samples | Sort-Object)
        return [PSCustomObject]@{
            Count  = $samples.Count
            Errors = $errors
            Avg    = if ($samples.Count -gt 0) { [int](($samples | Measure-Object -Average).Average) } else { 0 }
            P50    = Get-Pct $sorted 50
            P90    = Get-Pct $sorted 90
            P95    = Get-Pct $sorted 95
            P99    = Get-Pct $sorted 99
            Max    = Get-Pct $sorted 100
        }
    }

    $perLabel = @{}
    foreach ($kv in $parsed.ByLabel.GetEnumerator()) {
        $perLabel[$kv.Key] = Get-Stats $kv.Value.Samples $kv.Value.Errors
    }

    return [PSCustomObject]@{
        Aggregate = Get-Stats $parsed.AllElapsed $parsed.TotalErrors
        ByLabel   = $perLabel
        Runs      = @()  # CSV mode doesn't track run identifiers
    }
}

# --- History-mode stats: per-sampler aggregates from NDJSON, no synthetic aggregate ---

function Get-HistoryStats {
    param(
        [Parameter(Mandatory)] [hashtable]$Cells,
        [Parameter(Mandatory)] [string]$Version,
        [Parameter(Mandatory)] [string]$Tier,
        [Parameter(Mandatory)] [ValidateSet('latest', 'median5')] [string]$Aggregate
    )

    # cellKey = "{version}__{tier}__{sampler}"
    # Exact field compare, not -like: version/tier are free-text and a glob
    # metacharacter ([ ] ? *) in either would make -like mis-match or throw.
    $relevantKeys = @($Cells.Keys | Where-Object {
        $parts = $_ -split '__', 3
        $parts.Count -eq 3 -and $parts[0] -eq $Version -and $parts[1] -eq $Tier
    })

    $perLabel    = @{}
    $matchedRuns = @{}

    foreach ($cellKey in $relevantKeys) {
        $sampler = ($cellKey -split '__', 3)[2]
        # Get-RunDate (from _history-helpers.ps1, dot-sourced before this function
        # runs) tolerates unparseable timestamps so one corrupt history blob
        # doesn't throw under $ErrorActionPreference="Stop". $null-valued sort
        # keys sort to the end; downstream Take-N logic still picks valid rows.
        $runs = @($Cells[$cellKey] | Sort-Object { Get-RunDate $_ } -Descending)
        if ($runs.Count -eq 0) { continue }

        $picked = if ($Aggregate -eq 'latest') { @($runs[0]) } else { @($runs | Select-Object -First 5) }

        # Track unique runs (by run_id) for the report header.
        foreach ($r in $picked) { $matchedRuns[[string]$r.run_id] = $r }

        # Get-Median works for n=1 (returns the single value), so latest and median5
        # share the same code path.
        $perLabel[$sampler] = [PSCustomObject]@{
            Count    = [int][math]::Round((Get-Median (@($picked | ForEach-Object { [double]$_.request_count }))), 0)
            Errors   = [int][math]::Round((Get-Median (@($picked | ForEach-Object { [double]$_.failure_count }))), 0)
            Avg      = [int][math]::Round((Get-Median (@($picked | ForEach-Object { [double]$_.avg_ms }))), 0)
            P50      = [int][math]::Round((Get-Median (@($picked | ForEach-Object { [double]$_.p50_ms }))), 0)
            P90      = [int][math]::Round((Get-Median (@($picked | ForEach-Object { [double]$_.p90_ms }))), 0)
            P95      = [int][math]::Round((Get-Median (@($picked | ForEach-Object { [double]$_.p95_ms }))), 0)
            P99      = [int][math]::Round((Get-Median (@($picked | ForEach-Object { [double]$_.p99_ms }))), 0)
            Max      = [int][math]::Round((Get-Median (@($picked | ForEach-Object { [double]$_.max_ms }))), 0)
            RunCount = $picked.Count
        }
    }

    return [PSCustomObject]@{
        Aggregate = $null  # NDJSON has per-sampler aggregates only - no faithful way to
                           # reconstruct true aggregate percentiles (would need raw samples).
        ByLabel   = $perLabel
        Runs      = @($matchedRuns.Values | Sort-Object { Get-RunDate $_ })
    }
}

# --- Render helpers ---

function Format-Delta {
    param ([int]$Baseline, [int]$Candidate)
    if ($Baseline -le 0) { return "n/a" }
    $delta = ($Candidate - $Baseline) / [double]$Baseline * 100
    $sign  = if ($delta -gt 0) { "+" } else { "" }
    return ("{0}{1:F0}%" -f $sign, $delta)
}

function Format-Cell {
    param ([int]$Baseline, [int]$Candidate, [int]$ThresholdPct)
    $delta = if ($Baseline -le 0) { 0 } else { [math]::Abs(($Candidate - $Baseline) / [double]$Baseline * 100) }
    $deltaStr = Format-Delta $Baseline $Candidate
    if ($delta -ge $ThresholdPct) { return "**$deltaStr**" }
    return $deltaStr
}

# --- Load + label ---

if ($isHistoryMode) {
    . "$PSScriptRoot/_history-helpers.ps1"

    if ($BaselineVersion -and $CandidateVersion) {
        $baselineVersion = $BaselineVersion;  $baselineTier = $Tier
        $candidateVersion = $CandidateVersion; $candidateTier = $Tier
        if (-not $BaselineLabel)  { $BaselineLabel  = "$BaselineVersion / $Tier" }
        if (-not $CandidateLabel) { $CandidateLabel = "$CandidateVersion / $Tier" }
    }
    else {
        $baselineVersion = $Version; $baselineTier = $BaselineTier
        $candidateVersion = $Version; $candidateTier = $CandidateTier
        if (-not $BaselineLabel)  { $BaselineLabel  = "$Version / $BaselineTier" }
        if (-not $CandidateLabel) { $CandidateLabel = "$Version / $CandidateTier" }
    }

    $cells = Get-HistoryCells `
        -Scenario $Scenario `
        -HistoryResourceGroup $HistoryResourceGroup `
        -StorageAccountName $StorageAccountName `
        -ContainerName $ContainerName `
        -Major $Major

    if ($cells.Count -eq 0) {
        Write-PipelineError "No history rows found for scenario '$Scenario'$(if ($Major) { " (major $Major)" }). Nothing to compare."
    }

    $baseline  = Get-HistoryStats -Cells $cells -Version $baselineVersion  -Tier $baselineTier  -Aggregate $Aggregate
    $candidate = Get-HistoryStats -Cells $cells -Version $candidateVersion -Tier $candidateTier -Aggregate $Aggregate

    if ($baseline.ByLabel.Count -eq 0) {
        Write-PipelineError "No history rows for baseline cell ($baselineVersion / $baselineTier / $Scenario). Has this combination ever run?"
    }
    if ($candidate.ByLabel.Count -eq 0) {
        Write-PipelineError "No history rows for candidate cell ($candidateVersion / $candidateTier / $Scenario). Has this combination ever run?"
    }
}
else {
    if (-not $BaselineLabel)  { $BaselineLabel  = "Baseline" }
    if (-not $CandidateLabel) { $CandidateLabel = "Candidate" }
    $baseline  = Get-RunStats $BaselinePath
    $candidate = Get-RunStats $CandidatePath
}

# --- Build report ---

$out = New-Object System.Text.StringBuilder
[void]$out.AppendLine("# Run comparison: $BaselineLabel to $CandidateLabel")
[void]$out.AppendLine()

if ($isHistoryMode) {
    $aggDescBaseline  = if ($Aggregate -eq 'median5') { "median across $($baseline.Runs.Count) run(s)" }  else { "latest run" }
    $aggDescCandidate = if ($Aggregate -eq 'median5') { "median across $($candidate.Runs.Count) run(s)" } else { "latest run" }
    [void]$out.AppendLine("- Source: history storage (``$StorageAccountName/$ContainerName``)")
    [void]$out.AppendLine("- Baseline:  $BaselineLabel - $aggDescBaseline ($(($baseline.Runs  | ForEach-Object { "#$($_.run_id)" }) -join ', '))")
    [void]$out.AppendLine("- Candidate: $CandidateLabel - $aggDescCandidate ($(($candidate.Runs | ForEach-Object { "#$($_.run_id)" }) -join ', '))")
}
else {
    [void]$out.AppendLine("- Baseline:  ``$BaselinePath``")
    [void]$out.AppendLine("- Candidate: ``$CandidatePath``")
}
[void]$out.AppendLine("- Significant-delta threshold: $SignificantDeltaPercent% (bold = at or above)")
[void]$out.AppendLine()

# Aggregate (CSV mode only - true aggregate percentiles need raw samples)
if ($baseline.Aggregate -and $candidate.Aggregate) {
    [void]$out.AppendLine("## Aggregate")
    [void]$out.AppendLine()
    [void]$out.AppendLine("| Tier | Count | Errors | Avg | p50 | p95 | p99 | Max |")
    [void]$out.AppendLine("|---|---|---|---|---|---|---|---|")
    $b = $baseline.Aggregate; $c = $candidate.Aggregate
    [void]$out.AppendLine("| **$BaselineLabel** | $($b.Count) | $($b.Errors) | $($b.Avg)ms | $($b.P50)ms | $($b.P95)ms | $($b.P99)ms | $($b.Max)ms |")
    [void]$out.AppendLine("| **$CandidateLabel** | $($c.Count) | $($c.Errors) | $($c.Avg)ms | $($c.P50)ms | $($c.P95)ms | $($c.P99)ms | $($c.Max)ms |")
    [void]$out.AppendLine("| Change | $(Format-Delta $b.Count $c.Count) | - | $(Format-Cell $b.Avg $c.Avg $SignificantDeltaPercent) | $(Format-Cell $b.P50 $c.P50 $SignificantDeltaPercent) | $(Format-Cell $b.P95 $c.P95 $SignificantDeltaPercent) | $(Format-Cell $b.P99 $c.P99 $SignificantDeltaPercent) | - |")
    [void]$out.AppendLine()
    [void]$out.AppendLine("> *Max metrics are dominated by single-sample outliers -- don't read into them across runs. p95/p99 are the reliable tier-discriminating metrics.*")
    [void]$out.AppendLine()
}
else {
    [void]$out.AppendLine("> *Aggregate row omitted: history mode reads per-sampler aggregates from NDJSON, and true aggregate percentiles can't be reconstructed without raw samples. Per-sampler comparison below is the actionable view.*")
    [void]$out.AppendLine()
}

# Per-sampler
[void]$out.AppendLine("## Per-sampler")
[void]$out.AppendLine()
[void]$out.AppendLine("| Sampler | $BaselineLabel count | $CandidateLabel count | Avg Change | p95 Change | p99 Change |")
[void]$out.AppendLine("|---|---|---|---|---|---|")

# Order by baseline count descending so heaviest samplers come first.
$labels = $baseline.ByLabel.Keys | Sort-Object { -$baseline.ByLabel[$_].Count }
foreach ($label in $labels) {
    $b = $baseline.ByLabel[$label]
    $c = $candidate.ByLabel[$label]
    if (-not $c) {
        [void]$out.AppendLine("| ``$label`` | $($b.Count) | (missing) | - | - | - |")
        continue
    }
    [void]$out.AppendLine("| ``$label`` | $($b.Count) | $($c.Count) | $(Format-Cell $b.Avg $c.Avg $SignificantDeltaPercent) | $(Format-Cell $b.P95 $c.P95 $SignificantDeltaPercent) | $(Format-Cell $b.P99 $c.P99 $SignificantDeltaPercent) |")
}

foreach ($label in ($candidate.ByLabel.Keys | Where-Object { -not $baseline.ByLabel.ContainsKey($_) })) {
    $c = $candidate.ByLabel[$label]
    [void]$out.AppendLine("| ``$label`` | (missing) | $($c.Count) | - | - | - |")
}

[void]$out.AppendLine()
[void]$out.AppendLine("## How to read this")
[void]$out.AppendLine()
[void]$out.AppendLine("- **Negative Change = candidate is faster.** A row showing ``-43%`` on p99 means the candidate's p99 latency is 43% lower than the baseline's.")
[void]$out.AppendLine("- **Bold values cross the significance threshold** ($SignificantDeltaPercent%). Skim the bold cells to find where the tier/version actually matters.")
[void]$out.AppendLine("- **p95/p99 are the tier-discriminating metrics.** p50 is mostly cache hits (similar across tiers); max is single-sample noise.")
[void]$out.AppendLine("- **Cached paths (Homepage) and static assets (Media) won't differentiate tiers** because their hot path doesn't touch the SQL DTU budget.")
[void]$out.AppendLine("- **Write paths (e.g. ContactFormSubmit) need enough volume to saturate the lower tier's Log IO.** If they barely move, increase the task weight on the write task.")

$report = $out.ToString()

if ($OutputPath) {
    $report | Out-File -FilePath $OutputPath -Encoding utf8
    Write-Host "Report written to $OutputPath"
} else {
    Write-Output $report
}
