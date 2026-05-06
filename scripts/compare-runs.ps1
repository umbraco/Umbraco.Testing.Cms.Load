# Compare two Locust runs (engine_results.csv files from Azure Load Testing)
# and emit a markdown report with per-sampler deltas.
#
# Usage:
#   ./scripts/compare-runs.ps1 -BaselinePath path\to\starter\engine1_results.csv `
#                              -CandidatePath path\to\standard\engine1_results.csv `
#                              -BaselineLabel "Starter" -CandidateLabel "Standard"
#
# Optional:
#   -OutputPath compare.md     # write to file instead of stdout
#   -SignificantDeltaPercent 10 # highlight rows where p95 or p99 moved by >= this %
#
# The CSV is JMeter format (which is what Azure Load Testing emits):
#   timeStamp,elapsed,label,responseCode,responseMessage,threadName,dataType,success,...

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)] [string]$BaselinePath,
    [Parameter(Mandatory = $true)] [string]$CandidatePath,
    [string]$BaselineLabel = "Baseline",
    [string]$CandidateLabel = "Candidate",
    [string]$OutputPath,
    [int]$SignificantDeltaPercent = 10
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $BaselinePath))   { throw "Baseline CSV not found: $BaselinePath" }
if (-not (Test-Path $CandidatePath))  { throw "Candidate CSV not found: $CandidatePath" }

function Get-RunStats {
    param ([string]$Path)

    # Stream-parse to keep memory bounded on Massive runs.
    $byLabel = @{}
    $allElapsed = New-Object 'System.Collections.Generic.List[int]'
    $totalRows = 0
    $totalErrors = 0

    $reader = [System.IO.StreamReader]::new($Path)
    try {
        $reader.ReadLine() | Out-Null  # discard header
        while ($null -ne ($line = $reader.ReadLine())) {
            $cols = $line.Split(',')
            if ($cols.Length -lt 8) { continue }
            $elapsed = 0
            if (-not [int]::TryParse($cols[1], [ref]$elapsed)) { continue }
            $label   = $cols[2]
            $success = $cols[7] -eq 'TRUE'

            $totalRows++
            if (-not $success) { $totalErrors++ }
            $allElapsed.Add($elapsed)

            $bucket = $byLabel[$label]
            if (-not $bucket) {
                $bucket = @{ Samples = (New-Object 'System.Collections.Generic.List[int]'); Errors = 0 }
                $byLabel[$label] = $bucket
            }
            $bucket.Samples.Add($elapsed)
            if (-not $success) { $bucket.Errors++ }
        }
    }
    finally { $reader.Dispose() }

    function Get-Pct ($sortedArr, [double]$pct) {
        if ($sortedArr.Count -eq 0) { return 0 }
        $i = [Math]::Min([int]($sortedArr.Count * $pct / 100.0), $sortedArr.Count - 1)
        return $sortedArr[$i]
    }

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
    foreach ($kv in $byLabel.GetEnumerator()) {
        $perLabel[$kv.Key] = Get-Stats $kv.Value.Samples $kv.Value.Errors
    }

    return [PSCustomObject]@{
        Aggregate = Get-Stats $allElapsed $totalErrors
        ByLabel   = $perLabel
    }
}

function Format-Delta {
    param ([int]$Baseline, [int]$Candidate)
    if ($Baseline -le 0) { return "n/a" }
    $delta = ($Candidate - $Baseline) / [double]$Baseline * 100
    $sign  = if ($delta -gt 0) { "+" } else { "" }
    return ("{0}{1:F0}%" -f $sign, $delta)
}

function Format-Cell {
    param ([int]$Baseline, [int]$Candidate, [int]$ThresholdPct)
    $delta = if ($Baseline -le 0) { 0 } else { [Math]::Abs(($Candidate - $Baseline) / [double]$Baseline * 100) }
    $deltaStr = Format-Delta $Baseline $Candidate
    if ($delta -ge $ThresholdPct) {
        return "**$deltaStr**"
    }
    return $deltaStr
}

$baseline  = Get-RunStats $BaselinePath
$candidate = Get-RunStats $CandidatePath

# ----- Build report -----
$out = New-Object System.Text.StringBuilder
[void]$out.AppendLine("# Run comparison: $BaselineLabel to $CandidateLabel")
[void]$out.AppendLine()
[void]$out.AppendLine("- Baseline:  ``$BaselinePath``")
[void]$out.AppendLine("- Candidate: ``$CandidatePath``")
[void]$out.AppendLine("- Significant-delta threshold: $SignificantDeltaPercent% (bold = at or above)")
[void]$out.AppendLine()

# Aggregate
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

# Labels only in candidate
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
    $report | Set-Content -Path $OutputPath -Encoding utf8
    Write-Host "Report written to $OutputPath"
} else {
    Write-Output $report
}
