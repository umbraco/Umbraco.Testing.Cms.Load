#requires -Version 7.3

# Print a per-sampler load test summary to the pipeline log, grouping JMeter
# Transaction Controller rows with their child HTTP samplers. Runs after
# AzureLoadTest@1 (which prints its own summary in dictionary-iteration order
# — parent and child rows interleaved unpredictably). This step reuses ALT's
# downloaded engine*_results.csv files so nothing extra is fetched.
#
# Frontend (Locust) runs have no transaction controllers; the script falls
# back to a flat sampler list.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$ResultsDir,
    [Parameter(Mandatory = $true)] [string]$TestCaseId
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/_helpers.ps1"

if (-not (Test-Path -LiteralPath $ResultsDir)) {
    Write-Host "Custom summary: no results dir at '$ResultsDir' (load test likely fast-failed); nothing to summarise."
    exit 0
}

# ALT zips engine output. Idempotent expand mirrors publish-load-test-results.ps1
# so the two scripts agree on layout regardless of execution order.
$resultsZips = @(Get-ChildItem -Path $ResultsDir -Recurse -Filter "results.zip" -File -ErrorAction SilentlyContinue)
foreach ($zip in $resultsZips) {
    $dest = Join-Path $zip.Directory.FullName ($zip.BaseName + "-extracted")
    if (-not (Test-Path $dest)) {
        Expand-Archive -Path $zip.FullName -DestinationPath $dest -Force
    }
}

$engineFiles = @(Get-ChildItem -Path $ResultsDir -Recurse -Filter "engine*_results.csv" -File -ErrorAction SilentlyContinue)
if ($engineFiles.Count -eq 0) {
    Write-Host "Custom summary: no engine*_results.csv files under '$ResultsDir'; nothing to summarise."
    exit 0
}

# Local parse — keeps Transaction Controller rows (publish-load-test-results.ps1's
# shared parser intentionally drops them; we WANT them here to drive grouping).
# TC heuristic matches the convention used in our .jmx test plans: '<NN>. Description'.
$tcPattern = '^\d+\.\s+'
$byLabel = @{}

foreach ($file in $engineFiles) {
    $reader = [System.IO.StreamReader]::new($file.FullName)
    try {
        $reader.ReadLine() | Out-Null  # header
        while ($null -ne ($line = $reader.ReadLine())) {
            $cols = $line.Split(',')
            if ($cols.Length -lt 8) { continue }
            $ts = 0L
            if (-not [long]::TryParse($cols[0], [ref]$ts)) { continue }
            $elapsed = 0
            if (-not [int]::TryParse($cols[1], [ref]$elapsed)) { continue }
            $label   = $cols[2]
            $success = $cols[7] -ieq 'true'

            $bucket = $byLabel[$label]
            if (-not $bucket) {
                $bucket = @{
                    Samples = (New-Object 'System.Collections.Generic.List[int]')
                    Errors  = 0
                    FirstTs = $ts
                    IsTC    = ($label -match $tcPattern)
                }
                $byLabel[$label] = $bucket
            }
            $bucket.Samples.Add($elapsed)
            if ($ts -lt $bucket.FirstTs) { $bucket.FirstTs = $ts }
            if (-not $success) { $bucket.Errors++ }
        }
    } finally { $reader.Dispose() }
}

if ($byLabel.Count -eq 0) {
    Write-Host "Custom summary: engine CSVs contained no parseable rows; nothing to summarise."
    exit 0
}

function Format-Stats {
    param([Parameter(Mandatory)] $Bucket)
    $sorted = [System.Collections.Generic.List[int]]::new($Bucket.Samples)
    $sorted.Sort()
    $n      = $sorted.Count
    $err    = $Bucket.Errors
    $errPct = if ($n -gt 0) { [math]::Round(100.0 * $err / $n, 1) } else { 0 }
    $avg    = if ($n -gt 0) { [math]::Round((($sorted | Measure-Object -Average).Average), 0) } else { 0 }
    $p95    = Get-Pct $sorted 95
    $max    = if ($n -gt 0) { $sorted[$sorted.Count - 1] } else { 0 }
    return ("{0,-6} {1,-7} {2,-8} {3,-8} {4}" -f $n, "${errPct}%", "${avg}ms", "${p95}ms", "${max}ms")
}

# 'Aggregate' is a JMeter synthetic listener row that sums every sampler — not a
# real test step. Pull it out so the TC grouping walk doesn't accidentally adopt
# it as a child of whichever TC happens to sit next to it in time order.
$syntheticLabels = @('Aggregate')

# JMeter emits the TC parent row AFTER its children finish, so sorting by
# first-seen timestamp gives: child1, TC1, child2, TC2, ... — walk and collapse
# each contiguous run of HTTP children into the TC that closes the run.
$orderedLabels = $byLabel.Keys | Where-Object { $syntheticLabels -notcontains $_ } | Sort-Object { $byLabel[$_].FirstTs }

$groups          = New-Object System.Collections.Generic.List[object]
$pendingChildren = New-Object System.Collections.Generic.List[string]
foreach ($label in $orderedLabels) {
    if ($byLabel[$label].IsTC) {
        $groups.Add([pscustomobject]@{
            TC       = $label
            Children = @($pendingChildren.ToArray())
        })
        $pendingChildren.Clear()
    } else {
        $pendingChildren.Add($label)
    }
}
# Anything left at the end = HTTP samplers with no closing TC. Frontend (Locust)
# runs land here entirely; backoffice rarely does (would mean a JMeter sampler
# outside any TC).
$orphans = @($pendingChildren.ToArray())
foreach ($synthetic in $syntheticLabels) {
    if ($byLabel.ContainsKey($synthetic)) { $orphans += $synthetic }
}

# Totals across HTTP samplers only (TCs duplicate their children's elapsed; the
# synthetic Aggregate would double-count too). This gives the "real work done"
# request count, which is what the load test was actually exercising.
$totalReqs = 0
$totalErrs = 0
foreach ($label in $byLabel.Keys) {
    if ($byLabel[$label].IsTC)         { continue }
    if ($syntheticLabels -contains $label) { continue }
    $totalReqs += $byLabel[$label].Samples.Count
    $totalErrs += $byLabel[$label].Errors
}
$totalErrPct = if ($totalReqs -gt 0) { [math]::Round(100.0 * $totalErrs / $totalReqs, 1) } else { 0 }

$header = "========== Custom load test summary [$TestCaseId] =========="
$footer = ('=' * $header.Length)

Write-Host ""
Write-Host $header
Write-Host "HTTP samplers only: $totalReqs requests, $totalErrs errors (${totalErrPct}%)"
Write-Host ""
Write-Host ("  {0,-55} {1,-6} {2,-7} {3,-8} {4,-8} {5}" -f "Sampler", "n", "err", "avg", "p95", "max")

# `[char]` cast avoids PS6+-only `\u` escape — works on any PowerShell parser.
$branchPrefix = "$([char]0x2514)$([char]0x2500)"

if ($groups.Count -gt 0) {
    foreach ($g in $groups) {
        $tcStats = Format-Stats -Bucket $byLabel[$g.TC]
        Write-Host ("  [TC] {0,-50} {1}" -f $g.TC, $tcStats)
        foreach ($child in $g.Children) {
            $cStats = Format-Stats -Bucket $byLabel[$child]
            Write-Host ("       {0} {1,-47} {2}" -f $branchPrefix, $child, $cStats)
        }
    }
}

if ($orphans.Count -gt 0) {
    if ($groups.Count -gt 0) {
        Write-Host ""
        Write-Host "Other:"
    }
    foreach ($label in $orphans) {
        $oStats = Format-Stats -Bucket $byLabel[$label]
        Write-Host ("  {0,-55} {1}" -f $label, $oStats)
    }
}

Write-Host $footer
Write-Host ""
