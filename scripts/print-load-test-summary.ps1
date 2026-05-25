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

# Two parallel buckets:
#   $byLabel — every label (HTTP child + TC parent), used for grouping order
#              (FirstTs) and HTTP-child stats.
#   $tcRecomputed — TC stats RECOMPUTED from children rather than read from the
#              JMeter TC row. The TC row's `success` flag is unreliable (we've
#              seen TCs report 100% fail while children were all 200 OK due to
#              JMeter assertion / redirect accounting on the parent). Real
#              transaction semantics: iteration fails iff any child failed,
#              iteration elapsed = sum of children's elapsed.
$tcPattern    = '^\d+\.\s+'
$byLabel      = @{}
$tcRecomputed = @{}

# CSV column layout (JMeter / ALT): timeStamp, elapsed, label, responseCode,
# responseMessage, threadName, dataType, success, failureMessage, ...
foreach ($file in $engineFiles) {
    # Per-thread iteration accumulator. Reset per engine file because thread
    # names are NOT unique across engines in multi-engine runs (each ALT engine
    # restarts the thread-number counter). Without this reset, engine2's
    # threadName "1. Member Login 1-1" would inherit engine1's pending children.
    $threadStates = @{}
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
            $label        = $cols[2]
            $responseCode = $cols[3]
            $threadName   = $cols[5]
            $success      = $cols[7] -ieq 'true'
            $isTc         = ($label -match $tcPattern)

            # Per-label bucket: used for grouping order (FirstTs) and for HTTP
            # child stats. For TC labels, only FirstTs matters — TC stats come
            # from $tcRecomputed below.
            $bucket = $byLabel[$label]
            if (-not $bucket) {
                $bucket = @{
                    Samples       = (New-Object 'System.Collections.Generic.List[int]')
                    Errors        = 0
                    FirstTs       = $ts
                    IsTC          = $isTc
                    # responseCode → count, only for non-2xx (debugging fast-fails).
                    # 2xx kept out so the summary doesn't list "200: 100" noise.
                    NonSuccessCodes = @{}
                }
                $byLabel[$label] = $bucket
            }
            $bucket.Samples.Add($elapsed)
            if ($ts -lt $bucket.FirstTs) { $bucket.FirstTs = $ts }
            if (-not $success) {
                $bucket.Errors++
                $codeKey = if ([string]::IsNullOrWhiteSpace($responseCode)) { '(blank)' } else { $responseCode }
                if (-not $bucket.NonSuccessCodes.ContainsKey($codeKey)) { $bucket.NonSuccessCodes[$codeKey] = 0 }
                $bucket.NonSuccessCodes[$codeKey]++
            }

            # Per-thread state machine that recomputes TCs from children.
            # JMeter emits TC parent row AFTER all its children for the same
            # iteration on the same thread, so a TC row closes the pending
            # iteration's elapsed-sum + failure-flag accumulated since the
            # previous TC (or start of thread).
            $state = $threadStates[$threadName]
            if (-not $state) {
                $state = @{ FailedFlag = $false; ElapsedSum = 0 }
                $threadStates[$threadName] = $state
            }

            if ($isTc) {
                $tcBucket = $tcRecomputed[$label]
                if (-not $tcBucket) {
                    $tcBucket = @{
                        Samples = (New-Object 'System.Collections.Generic.List[int]')
                        Errors  = 0
                    }
                    $tcRecomputed[$label] = $tcBucket
                }
                $tcBucket.Samples.Add($state.ElapsedSum)
                if ($state.FailedFlag) { $tcBucket.Errors++ }
                $state.FailedFlag = $false
                $state.ElapsedSum = 0
            } else {
                $state.ElapsedSum += $elapsed
                if (-not $success) { $state.FailedFlag = $true }
            }
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

# Render the response-code distribution for a label as "  codes: 400=100, 503=2"
# (sorted by count desc). Empty string when the label had no failures, so the
# happy-path summary stays one line per sampler.
function Format-ResponseCodes {
    param([Parameter(Mandatory)] $Bucket)
    if (-not $Bucket.NonSuccessCodes -or $Bucket.NonSuccessCodes.Count -eq 0) { return '' }
    $pairs = $Bucket.NonSuccessCodes.GetEnumerator() |
        Sort-Object -Property Value -Descending |
        ForEach-Object { "$($_.Key)=$($_.Value)" }
    return "  codes: $($pairs -join ', ')"
}

if ($groups.Count -gt 0) {
    foreach ($g in $groups) {
        # TC stats come from $tcRecomputed (children-derived) rather than the
        # JMeter TC row in $byLabel, which can disagree with reality.
        $tcBucket = if ($tcRecomputed.ContainsKey($g.TC)) { $tcRecomputed[$g.TC] } else { $byLabel[$g.TC] }
        $tcStats  = Format-Stats -Bucket $tcBucket
        Write-Host ("  [TC] {0,-50} {1}" -f $g.TC, $tcStats)
        foreach ($child in $g.Children) {
            $cBucket = $byLabel[$child]
            $cStats  = Format-Stats -Bucket $cBucket
            $cCodes  = Format-ResponseCodes -Bucket $cBucket
            Write-Host ("       {0} {1,-47} {2}{3}" -f $branchPrefix, $child, $cStats, $cCodes)
        }
    }
}

if ($orphans.Count -gt 0) {
    if ($groups.Count -gt 0) {
        Write-Host ""
        Write-Host "Other:"
    }
    foreach ($label in $orphans) {
        $oBucket = $byLabel[$label]
        $oStats  = Format-Stats -Bucket $oBucket
        $oCodes  = Format-ResponseCodes -Bucket $oBucket
        Write-Host ("  {0,-55} {1}{2}" -f $label, $oStats, $oCodes)
    }
}

Write-Host $footer
Write-Host ""
