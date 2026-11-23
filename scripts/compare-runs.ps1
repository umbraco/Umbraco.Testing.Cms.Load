#requires -Version 7.3

# Compare two runs - or, in history mode, two or more versions - and emit a
# markdown report with per-sampler deltas.
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
#   # several versions side by side on a fixed tier (first one is the reference)
#   ./scripts/compare-runs.ps1 -Scenario Default -Tier Starter `
#       -Versions 17.6.1,18.0.0,19.0.0-beta1 -Aggregate median `
#       -HistoryResourceGroup umbraco-loadtest-history-rg `
#       -StorageAccountName loadtesthistory -ContainerName loadtest-history
#
#   Aggregate mode: 'latest' (default) takes the most recent run per cell;
#   'median' takes the median across the last -Window runs (default 5; more
#   stable on noisy tails). 'median5' is kept as 'median -Window 5'.
#   Either way a cell only counts runs that drove the same load, on the same
#   setup (SKU, DTU cap, seeder preset and build), as its newest run, and the
#   report warns when the sides differ.
#
#   To take the median of exactly the runs you queued, rather than whatever is
#   newest, scope history with -RunIds (build ids) and/or -Since:
#   ./scripts/compare-runs.ps1 -Scenario Default -Tier Starter `
#       -Versions 18.3.2,19.0.0-rc1 -Aggregate median -Window 5 `
#       -RunIds 4101,4102,4103,4104,4105,4106,4107,4108,4109,4110 `
#       -HistoryResourceGroup umbraco-loadtest-history-rg `
#       -StorageAccountName loadtesthistory -ContainerName loadtest-history
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

    # multi-version: -Tier shared, two or more exact version strings. The first
    # is the reference every other version's change is measured against.
    [string[]]$Versions,

    # tier-vs-tier: -Version shared, -BaselineTier + -CandidateTier vary
    [string]$Version,
    [string]$BaselineTier,
    [string]$CandidateTier,

    [ValidateSet('latest', 'median', 'median5')] [string]$Aggregate = 'latest',
    # Runs per cell the median is taken over ('median' only).
    [ValidateRange(2, 100)] [int]$Window = 5,
    # History mode: only these build ids (run_id) / only runs started at or
    # after this time count. Use them to pin a median to the runs you queued.
    [string[]]$RunIds,
    [Nullable[datetime]]$Since,
    # History mode: build ids to leave out entirely - a run you know was
    # invalid (an Azure hiccup, a wrong override). Applied before -Window, so
    # the next older like-for-like run takes its place. Listed in the report.
    [string[]]$ExcludeRunIds,
    # History mode, percent: a (run, sampler) whose error rate is above this
    # is left out of the LATENCY medians, but still counted in the error rate,
    # and named in the report. Off (negative) by default. Applied after
    # -Window: a failing run is a result, so it isn't replaced.
    [double]$MaxErrorRate = -1,

    # Common
    [string]$BaselineLabel,
    [string]$CandidateLabel,
    [string]$OutputPath,
    [int]$SignificantDeltaPercent = 10,

    # CSV mode, backoffice (JMeter) runs only: matches publish-load-test-results.ps1's
    # $onlyTC flip (set whenever JmeterTestName is non-empty) so a backoffice engine
    # CSV compares by "01. <step>" Transaction Controller rows, the same rows history
    # mode and the workbook use - not the dozens of raw per-request sampler rows.
    [switch]$OnlyTransactionControllers
)

$ErrorActionPreference = "Stop"

# Native commands (az CLI in history mode) honour $ErrorActionPreference.
$PSNativeCommandUseErrorActionPreference = $true

. "$PSScriptRoot/_helpers.ps1"

# 'median5' predates -Window: it is 'median' over 5 runs.
if ($Aggregate -eq 'median5') {
    $Aggregate = 'median'
    if (-not $PSBoundParameters.ContainsKey('Window')) { $Window = 5 }
}

# Run ids arrive as an array, as one comma-joined string (`pwsh -File`), or
# copied from a report with the '#': normalise once so every use agrees.
$RunIds        = @($RunIds        | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim().TrimStart('#') } | Where-Object { $_ })
$ExcludeRunIds = @($ExcludeRunIds | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim().TrimStart('#') } | Where-Object { $_ })

# --- Mode detection + validation ---

$isCsvMode     = $BaselinePath -or $CandidatePath
$isHistoryMode = $Scenario -or $HistoryResourceGroup -or $StorageAccountName -or $ContainerName

if ($isCsvMode -and $isHistoryMode) {
    Write-PipelineError "Specify EITHER CSV mode (-BaselinePath/-CandidatePath) OR history mode (-Scenario/-HistoryResourceGroup/-StorageAccountName/-ContainerName) - not both."
}
if (-not ($isCsvMode -or $isHistoryMode)) {
    Write-PipelineError "Specify either CSV mode (-BaselinePath + -CandidatePath) or history mode (-Scenario + -HistoryResourceGroup + -StorageAccountName + -ContainerName, plus -Tier with -BaselineVersion/-CandidateVersion or -Versions, or -Version with -BaselineTier/-CandidateTier)."
}

if ($isCsvMode) {
    if (-not ($BaselinePath -and $CandidatePath)) {
        Write-PipelineError "CSV mode requires both -BaselinePath and -CandidatePath."
    }
    if (-not (Test-Path $BaselinePath))  { Write-PipelineError "Baseline CSV not found: $BaselinePath" }
    if (-not (Test-Path $CandidatePath)) { Write-PipelineError "Candidate CSV not found: $CandidatePath" }
}

if ($isHistoryMode) {
    # -HistoryResourceGroup included: the storage key lookup needs it, and
    # without this check its absence surfaces as a parameter-binding error.
    if (-not ($Scenario -and $HistoryResourceGroup -and $StorageAccountName -and $ContainerName)) {
        Write-PipelineError "History mode requires -Scenario, -HistoryResourceGroup, -StorageAccountName, and -ContainerName."
    }
    # `pwsh -File` hands "-Versions a,b,c" over as the single string 'a,b,c'
    # rather than three elements, so split here to make both call styles work.
    $Versions = @($Versions | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    $isVersionPair = $BaselineVersion -and $CandidateVersion
    $isTierPair    = $BaselineTier -and $CandidateTier
    $isVersionList = $Versions.Count -gt 0
    if (@($isVersionPair, $isTierPair, $isVersionList | Where-Object { $_ }).Count -gt 1) {
        Write-PipelineError "History mode: choose ONE comparison axis - version-vs-version (with shared -Tier), multi-version (-Versions with shared -Tier) OR tier-vs-tier (with shared -Version)."
    }
    if (-not ($isVersionPair -or $isTierPair -or $isVersionList)) {
        Write-PipelineError "History mode: provide version-vs-version (-Tier + -BaselineVersion + -CandidateVersion), multi-version (-Tier + -Versions) or tier-vs-tier (-Version + -BaselineTier + -CandidateTier)."
    }
    if ($isVersionList -and $Versions.Count -lt 2) {
        Write-PipelineError "-Versions needs at least two versions to compare (got '$($Versions -join ', ')')."
    }
    if (($isVersionPair -or $isVersionList) -and -not $Tier) {
        Write-PipelineError "Version comparison requires -Tier (the shared tier)."
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
    $parsed = Parse-JmeterCsv -Path $Path -BuildAggregate -OnlyTransactionControllers:$OnlyTransactionControllers

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
        [Parameter(Mandatory)] [ValidateSet('latest', 'median')] [string]$Aggregate,
        [int]$Window = 5,
        # Percent; negative = off. See -MaxErrorRate on the script.
        [double]$MaxErrorRate = -1
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
    $overLimit   = [System.Collections.Generic.List[object]]::new()

    foreach ($cellKey in $relevantKeys) {
        $sampler = ($cellKey -split '__', 3)[2]
        # Select-LikeForLikeRuns (from _history-helpers.ps1, dot-sourced before
        # this function runs) sorts newest-first and keeps only runs that drove
        # the same load on the same setup as the newest one, so 'median' can't
        # fold a smoke, ramp or override run in with the standard runs around it.
        $window = if ($Aggregate -eq 'latest') { 1 } else { $Window }
        $picked = @(Select-LikeForLikeRuns -Runs @($Cells[$cellKey]) -First $window)
        if ($picked.Count -eq 0) { continue }

        # Track unique runs (by run_id) for the report header.
        foreach ($r in $picked) { $matchedRuns[[string]$r.run_id] = $r }

        # Error limit, per run AND sampler: a run whose one page failed keeps
        # its other pages. Over-limit rows leave the LATENCY medians only - an
        # instant failure is fast, so it would drag p50/p95 down and flatter the
        # version - and stay in the error rate and request counts, so a version
        # that fails is still reported as failing. Applied after the window: a
        # failing run is a result, not a mistake, so it isn't swapped for an
        # older run (unlike -ExcludeRunIds).
        # (Split-ByErrorLimit in _history-helpers.ps1; when every run is over
        # the limit it falls back to all runs and sets AllOver.)
        $split   = Split-ByErrorLimit -Runs $picked -MaxErrorRate $MaxErrorRate
        $latency = @($split.Latency)
        $allOver = $split.AllOver
        foreach ($r in @($split.Over)) {
            $overLimit.Add([pscustomobject]@{ RunId = [string]$r.run_id; Sampler = $sampler; ErrPct = [math]::Round([double]$r.error_rate * 100, 1) })
        }

        # Get-Median works for n=1 (returns the single value), so latest and median
        # share the same code path.
        $perLabel[$sampler] = [PSCustomObject]@{
            Count    = [int][math]::Round((Get-Median (@($picked | ForEach-Object { [double]$_.request_count }))), 0)
            Errors   = [int][math]::Round((Get-Median (@($picked | ForEach-Object { [double]$_.failure_count }))), 0)
            Avg      = [int][math]::Round((Get-Median (@($latency | ForEach-Object { [double]$_.avg_ms }))), 0)
            P50      = [int][math]::Round((Get-Median (@($latency | ForEach-Object { [double]$_.p50_ms }))), 0)
            P90      = [int][math]::Round((Get-Median (@($latency | ForEach-Object { [double]$_.p90_ms }))), 0)
            P95      = [int][math]::Round((Get-Median (@($latency | ForEach-Object { [double]$_.p95_ms }))), 0)
            P99      = [int][math]::Round((Get-Median (@($latency | ForEach-Object { [double]$_.p99_ms }))), 0)
            Max      = [int][math]::Round((Get-Median (@($latency | ForEach-Object { [double]$_.max_ms }))), 0)
            # Fastest request per run: the latency floor (network + a cached
            # response). It barely moves with the code under test, so a shift
            # here points at the environment rather than the version.
            Min      = [int][math]::Round((Get-Median (@($latency | ForEach-Object { [double]$_.min_ms }))), 0)
            ErrPct   = [math]::Round((Get-Median (@($picked | ForEach-Object { [double]$_.error_rate }))) * 100, 2)
            # Worst single run. A median hides failures up to just under half
            # the runs - two of five at 40% errors still reads 0% - so the
            # error table shows this beside it whenever it is higher.
            ErrMaxPct = [math]::Round((@($picked | ForEach-Object { [double]$_.error_rate }) | Measure-Object -Maximum).Maximum * 100, 2)
            # Run-to-run spread of each latency median, for the multi-version table.
            P50Std   = [int][math]::Round((Get-PopulationStdDev (@($latency | ForEach-Object { [double]$_.p50_ms }))), 0)
            P95Std   = [int][math]::Round((Get-PopulationStdDev (@($latency | ForEach-Object { [double]$_.p95_ms }))), 0)
            P99Std   = [int][math]::Round((Get-PopulationStdDev (@($latency | ForEach-Object { [double]$_.p99_ms }))), 0)
            MinStd   = [int][math]::Round((Get-PopulationStdDev (@($latency | ForEach-Object { [double]$_.min_ms }))), 0)
            LoadKey  = Get-LoadKey $picked[0]
            RunCount = $picked.Count
            # Runs behind the latency figures: fewer than RunCount when some went
            # over the error limit; 0 when all did (AllOverLimit).
            LatencyRunCount = if ($allOver) { 0 } else { $latency.Count }
            AllOverLimit    = $allOver
        }
    }

    return [PSCustomObject]@{
        Aggregate = $null  # NDJSON has per-sampler aggregates only - no faithful way to
                           # reconstruct true aggregate percentiles (would need raw samples).
        OverLimit = @($overLimit)
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
    $deltaStr = Format-Delta $Baseline $Candidate
    # A zero baseline going to a nonzero candidate is the most extreme possible
    # regression - bold it same as Format-Delta's "n/a", don't silently treat
    # it as insignificant.
    if ($Baseline -le 0) { return $(if ($Candidate -gt 0) { "**$deltaStr**" } else { $deltaStr }) }
    $delta = [math]::Abs(($Candidate - $Baseline) / [double]$Baseline * 100)
    if ($delta -ge $ThresholdPct) { return "**$deltaStr**" }
    return $deltaStr
}

# Samplers whose picked runs drove different loads across the given sides.
# A delta between e.g. 50-VU and 20-VU runs says nothing about the versions.
function Get-LoadMismatches {
    param([Parameter(Mandatory)] [object[]]$Sides, [Parameter(Mandatory)] [string[]]$Labels)
    $samplers = @($Sides | ForEach-Object { $_.ByLabel.Keys } | Sort-Object -Unique)
    foreach ($sampler in $samplers) {
        $loads = for ($i = 0; $i -lt $Sides.Count; $i++) {
            $s = $Sides[$i].ByLabel[$sampler]
            if ($s) { [pscustomobject]@{ Label = $Labels[$i]; LoadKey = $s.LoadKey } }
        }
        if (@($loads | ForEach-Object { $_.LoadKey } | Sort-Object -Unique).Count -gt 1) {
            [pscustomobject]@{
                Sampler = $sampler
                Detail  = (@($loads | ForEach-Object { "$($_.Label): $(Format-LoadKey $_.LoadKey)" }) -join '; ')
            }
        }
    }
}

function Add-LoadMismatchWarning {
    param([Parameter(Mandatory)] [System.Text.StringBuilder]$Out, [AllowEmptyCollection()] [object[]]$Mismatches)
    if (-not $Mismatches -or $Mismatches.Count -eq 0) { return }
    [void]$Out.AppendLine("> **Not like-for-like - the samplers below were measured differently on each side.** Either the runs drove different loads (VUs, spawn rate, duration) or their stats were computed under different methodology versions; the lines below show which. Their deltas reflect that difference, not the version/tier. Re-run the odd side at the same profile on the current harness before reading them.")
    foreach ($m in $Mismatches) {
        [void]$Out.AppendLine("> - ``$($m.Sampler)`` - $($m.Detail)")
    }
    [void]$Out.AppendLine()
}

# What was left out of the medians and why: runs excluded by hand, and
# (run, sampler) rows over -MaxErrorRate. Nothing is dropped without being
# named here. A side where most rows went over the limit gets a louder
# warning: there the errors are the result, not noise around it.
# Pair mode's counterpart of the per-version setup check in -Versions mode:
# each side's median is like-for-like within itself, but the two sides can
# still have run on different hardware (a queue-time override on one of them).
# The seeder build is left out for the same reason as there - it differs per
# major by design. -PresetOnly is for tier-vs-tier: the SKU and DTU cap are
# what a tier IS (loadtests/tiers.json), so only the seeder preset can be off.
function Add-SetupMismatchWarning {
    param([System.Text.StringBuilder] $Out, [object[]] $Sides, [string[]] $Labels, [switch] $PresetOnly)
    $fields = @(
        @{ Label = 'app SKU';       Field = 'app_service_sku' },
        @{ Label = 'DTU cap';       Field = 'pool_dtu_max' },
        @{ Label = 'seeder preset'; Field = 'seeder_preset' }
    )
    if ($PresetOnly) { $fields = @($fields | Where-Object { $_.Field -eq 'seeder_preset' }) }
    $differs = @()
    foreach ($f in $fields) {
        $field   = $f.Field
        $perSide = @(foreach ($side in $Sides) {
            (@($side.Runs | ForEach-Object { "$($_.$field)" } | Where-Object { $_ } | Sort-Object -Unique) -join '/')
        })
        if (@($perSide | Where-Object { $_ } | Sort-Object -Unique).Count -gt 1) {
            $parts = @(for ($i = 0; $i -lt $Sides.Count; $i++) { "$($Labels[$i]): $(if ($perSide[$i]) { $perSide[$i] } else { 'not recorded' })" })
            $differs += "$($f.Label) ($($parts -join '; '))"
        }
    }
    if ($differs.Count -gt 0) {
        [void]$Out.AppendLine("> **The runs compared were not on the same setup:** $($differs -join ', '). A queue-time override was probably used on one side; changes below may come from that rather than the version.")
        [void]$Out.AppendLine()
    }
}

function Add-ExclusionNotes {
    param([Parameter(Mandatory)] [System.Text.StringBuilder]$Out, [Parameter(Mandatory)] [object[]]$Sides, [Parameter(Mandatory)] [string[]]$Labels)
    $excludedIds = @($ExcludeRunIds)   # normalised at the top of the script
    if ($excludedIds.Count -gt 0) {
        [void]$Out.AppendLine("> **Excluded by you:** $(($excludedIds | ForEach-Object { "#$_" }) -join ', ') - left out entirely; with a window, the next older like-for-like run took each one's place.")
        [void]$Out.AppendLine()
    }
    if ($MaxErrorRate -lt 0) { return }
    $lines = @(); $failing = @()
    for ($i = 0; $i -lt $Sides.Count; $i++) {
        $over = @($Sides[$i].OverLimit)
        if ($over.Count -eq 0) { continue }
        $lines += "> - **$($Labels[$i])**: " + ((@($over | Sort-Object RunId, Sampler | ForEach-Object { "#$($_.RunId) ``$($_.Sampler)`` ($($_.ErrPct)%)" })) -join ', ')
        $rows = @($Sides[$i].ByLabel.Values | ForEach-Object { $_.RunCount } | Measure-Object -Sum).Sum
        $allOver = @($Sides[$i].ByLabel.GetEnumerator() | Where-Object { $_.Value.AllOverLimit } | ForEach-Object { $_.Key })
        if ($over.Count * 2 -gt $rows -or $allOver.Count -gt 0) {
            # Built outside the string: backticks next to a nested "$(...)" are
            # easy to get wrong, and a dropped one breaks the markdown.
            $allOverNames = (@($allOver | Sort-Object | ForEach-Object { '`' + $_ + '`' })) -join ', '
            $failing += $(if ($allOver.Count -gt 0) { "$($Labels[$i]) (every run over the limit on $allOverNames)" } else { "$($Labels[$i])" })
        }
    }
    if ($lines.Count -eq 0) {
        [void]$Out.AppendLine("> *Error limit $MaxErrorRate%: no run went over it, so nothing was left out of the latency medians.*")
        [void]$Out.AppendLine()
        return
    }
    [void]$Out.AppendLine("> **Left out of the latency medians - error rate over $MaxErrorRate%** (still counted in the error table):")
    foreach ($l in $lines) { [void]$Out.AppendLine($l) }
    [void]$Out.AppendLine()
    if ($failing.Count -gt 0) {
        [void]$Out.AppendLine("> **Failing, not noisy: $($failing -join '; ').** Most of its rows went over the error limit - the errors are the finding here, and its latency figures rest on the few runs that didn't fail (or, where every run failed, on the failing runs themselves).")
        [void]$Out.AppendLine()
    }
}

# Change cell for the multi-version tables. Values are whole milliseconds, so
# on a 4 ms p50 a single millisecond is +25%: bolding on percentage alone would
# flag integer granularity. A change is only bold when it also exceeds 1 ms and
# the larger of the two run-to-run spreads.
function Format-VersionChange {
    param ([int]$Reference, [int]$Value, [int]$ReferenceSpread, [int]$ValueSpread, [int]$ThresholdPct)
    $text     = Format-Delta $Reference $Value
    $absolute = [math]::Abs($Value - $Reference)
    $noise    = [math]::Max(1, [math]::Max($ReferenceSpread, $ValueSpread))
    # No percentage exists against a zero reference; the absolute test still applies.
    if ($Reference -le 0) { return $(if ($absolute -gt $noise) { "**$text**" } else { $text }) }
    $percent  = $absolute / [double]$Reference * 100
    if ($percent -ge $ThresholdPct -and $absolute -gt $noise) { return "**$text**" }
    return $text
}

function Write-Report([string]$Report) {
    if ($OutputPath) {
        $Report | Out-File -FilePath $OutputPath -Encoding utf8
        Write-Host "Report written to $OutputPath"
    } else {
        Write-Output $Report
    }
}

# --- Multi-version report (history mode, -Versions) ---

if ($isHistoryMode -and $isVersionList) {
    . "$PSScriptRoot/_history-helpers.ps1"

    $cells = Get-HistoryCells `
        -Scenario $Scenario `
        -HistoryResourceGroup $HistoryResourceGroup `
        -StorageAccountName $StorageAccountName `
        -ContainerName $ContainerName `
        -Major $Major `
        -OnlyRunIds $RunIds -Since $Since -ExcludeRunIds $ExcludeRunIds

    if ($cells.Count -eq 0) {
        Write-PipelineError "No history rows found for scenario '$Scenario'$(if ($Major) { " (major $Major)" }). Nothing to compare."
    }

    $sides = @(foreach ($v in $Versions) {
        $stats = Get-HistoryStats -Cells $cells -Version $v -Tier $Tier -Aggregate $Aggregate -Window $Window -MaxErrorRate $MaxErrorRate
        if ($stats.ByLabel.Count -eq 0) {
            Write-PipelineError "No history rows for cell ($v / $Tier / $Scenario). Version strings are matched exactly - has this combination ever run?$(if ($Major) { " -Major $Major also limits the search to that major; drop it when comparing across majors." })"
        }
        $stats
    })

    $reference  = $sides[0]
    $mismatches = @(Get-LoadMismatches -Sides $sides -Labels $Versions)

    $out = New-Object System.Text.StringBuilder
    [void]$out.AppendLine("# Version comparison on ${Tier}: $($Versions -join ' / ')")
    [void]$out.AppendLine()
    [void]$out.AppendLine("- Source: history storage (``$StorageAccountName/$ContainerName``), scenario ``$Scenario``")
    $aggText = if ($Aggregate -eq 'median') { "median across the last $Window like-for-like runs per sampler (same load and setup; fewer when fewer exist)" } else { 'latest run per sampler' }
    if ($RunIds) { $aggText += "; limited to runs $((@($RunIds) | ForEach-Object { "#$_" }) -join ', ')" }
    if ($Since)  { $aggText += "; runs started on or after $((ConvertTo-SinceUtc ([datetime]$Since)).ToString('dd-MM-yyyy HH:mm', [cultureinfo]::InvariantCulture)) UTC" }
    [void]$out.AppendLine("- Aggregate: $aggText")
    $seededFields = @(
        @{ Label = 'content';       Field = 'seeded_content_total' },
        @{ Label = 'root sections'; Field = 'seeded_root_sections' },
        @{ Label = 'media images';  Field = 'seeded_media_images' },
        @{ Label = 'media files';   Field = 'seeded_media_files' }
    )
    # Every value seen per field across all versions, to flag a content mismatch below.
    $seededSeen = @{}
    foreach ($f in $seededFields) { $seededSeen[$f.Field] = @() }
    # Versions with at least one picked run that recorded no content count.
    $seededUnverified = @()
    # The queue-time overrides (seederPresetOverride / appSkuOverride /
    # poolDtuOverride) change what a run measured without changing its cell or
    # its load key, so they are listed per version and checked here instead.
    $infraFields = @(
        @{ Label = 'seeder preset'; Field = 'seeder_preset' },
        @{ Label = 'app SKU';       Field = 'app_service_sku' },
        @{ Label = 'DTU cap';       Field = 'pool_dtu_max' },
        @{ Label = 'seeder build';  Field = 'seeder_package_version' }
    )
    $infraSeen = @{}
    foreach ($f in $infraFields) { $infraSeen[$f.Field] = @() }
    for ($i = 0; $i -lt $Versions.Count; $i++) {
        $runs    = @($sides[$i].Runs)
        $ids     = (@($runs | ForEach-Object { "#$($_.run_id)" }) -join ', ')
        $loads   = (@($sides[$i].ByLabel.Values | ForEach-Object { $_.LoadKey } | Sort-Object -Unique | ForEach-Object { Format-LoadKey $_ }) -join ' / ')
        $dotnet  = (@($runs | ForEach-Object { [string]$_.dotnet_version } | Where-Object { $_ } | Sort-Object -Unique) -join ', ')
        $commits = (@($runs | ForEach-Object { $c = [string]$_.commit; if ($c.Length -gt 7) { $c.Substring(0, 7) } else { $c } } | Where-Object { $_ } | Sort-Object -Unique) -join ', ')
        # Seeded content as the runs themselves reported it. More than one value
        # per field means the runs behind this version did not hold the same content.
        $seeded = (@($seededFields | ForEach-Object {
            $field  = $_.Field
            $values = @($runs | ForEach-Object { $_.$field } | Where-Object { $null -ne $_ -and "$_" -ne '' } | Sort-Object -Unique)
            if ($values.Count -gt 0) {
                $seededSeen[$field] += @($values)
                "$($_.Label) $($values -join '/')"
            }
        }) -join ', ')
        if (-not $seeded) { $seeded = 'not recorded' }
        if (@($runs | Where-Object { $null -eq $_.seeded_content_total -or "$($_.seeded_content_total)" -eq '' }).Count -gt 0) {
            $seededUnverified += $Versions[$i]
        }
        $infra = (@($infraFields | ForEach-Object {
            $field  = $_.Field
            $values = @($runs | ForEach-Object { $_.$field } | Where-Object { $null -ne $_ -and "$_" -ne '' } | ForEach-Object { "$_" } | Sort-Object -Unique)
            if ($values.Count -gt 0) {
                $infraSeen[$field] += @($values)
                "$($_.Label) $($values -join '/')"
            }
        }) -join ', ')
        if (-not $infra) { $infra = 'setup not recorded' }
        [void]$out.AppendLine("- **$($Versions[$i])**: $($runs.Count) run(s) ($ids); load: $loads; .NET $dotnet; harness commit(s) $commits; $infra; seeded: $seeded")
    }
    [void]$out.AppendLine("- Change columns are relative to **$($Versions[0])**; bold = at or above $SignificantDeltaPercent% and larger than both 1 ms and the run-to-run spread. Negative = faster.")
    [void]$out.AppendLine("- ``±`` is the run-to-run standard deviation of the value beside it (shown when a cell has 2+ runs). A change smaller than the spread is noise.")
    if ($MaxErrorRate -ge 0) {
        [void]$out.AppendLine("- Error limit for latency: $MaxErrorRate%. ``(n=K)`` after a latency value = it rests on K runs because the others went over the limit; ``!`` = every run went over it, so the value is the latency of failing runs and no change is computed against it (``n/c``). Error rates always count every run.")
    }
    if ($mismatches.Count -gt 0) {
        [void]$out.AppendLine("- ``*`` marks a value measured under a different load or methodology version than **$($Versions[0])**; no change is computed for it (``n/c``).")
    }
    [void]$out.AppendLine()
    Add-LoadMismatchWarning -Out $out -Mismatches $mismatches
    Add-ExclusionNotes -Out $out -Sides $sides -Labels $Versions

    # A median over fewer runs than asked for is weaker than it looks, and when
    # samplers show different counts their medians came from different runs.
    if ($Aggregate -eq 'median') {
        $short = @(for ($i = 0; $i -lt $Versions.Count; $i++) {
            $counts = @($sides[$i].ByLabel.Values | ForEach-Object { $_.RunCount } | Sort-Object -Unique)
            if (($counts | Measure-Object -Minimum).Minimum -lt $Window) {
                "$($Versions[$i]) (n=$($counts -join '/'))"
            }
        })
        if ($short.Count -gt 0) {
            [void]$out.AppendLine("> **Fewer runs than the $Window asked for:** $($short -join ', '). Those medians rest on fewer runs, and where several n values are shown the samplers took their medians over different runs. Check the run ids above against the runs you queued.")
            [void]$out.AppendLine()
        }
    }

    # The seeder build is listed per version but left out of this warning: each
    # major has its own build, so it always differs across majors, and whether
    # the content matched is what the seeded-content check below answers. Within
    # one version a different build can't share a median (Select-LikeForLikeRuns).
    $infraDiffers = @($infraFields | Where-Object { $_.Field -ne 'seeder_package_version' } | Where-Object { @($infraSeen[$_.Field] | Sort-Object -Unique).Count -gt 1 } | ForEach-Object { $_.Label })
    if ($infraDiffers.Count -gt 0) {
        [void]$out.AppendLine("> **The runs compared were not on the same setup** ($($infraDiffers -join ', ') differ - see the per-version lines above). A queue-time override was probably used on some of them; changes below may come from that rather than the version.")
        [void]$out.AppendLine()
    }

    # The counts are recorded so this can be checked rather than assumed: each
    # major uses its own seeder build, and different content is a different test.
    $seededDiffers = @($seededFields | Where-Object { @($seededSeen[$_.Field] | Sort-Object -Unique).Count -gt 1 } | ForEach-Object { $_.Label })
    if ($seededDiffers.Count -gt 0) {
        [void]$out.AppendLine("> **Seeded content differs between the runs compared** ($($seededDiffers -join ', ') - see the per-version lines above). The sites did not hold the same content, so part of any change below may come from the content rather than the version.")
        [void]$out.AppendLine()
    }
    elseif ($seededUnverified.Count -gt 0) {
        # Absent counts are not agreement: say the check could not be made.
        [void]$out.AppendLine("> *Seeded content not verified for $($seededUnverified -join ', '): at least one of the runs counted has no recorded content counts (run before the counts were captured, or with warm-up skipped). Equal content across versions is assumed there, not checked.*")
        [void]$out.AppendLine()
    }

    # Heaviest reference samplers first, then any the reference never ran.
    $labels = @($reference.ByLabel.Keys | Sort-Object { -$reference.ByLabel[$_].Count }) +
              @($sides | Select-Object -Skip 1 | ForEach-Object { $_.ByLabel.Keys } | Sort-Object -Unique | Where-Object { -not $reference.ByLabel.ContainsKey($_) })

    $header = "| Sampler | $($Versions[0]) |" + ((@($Versions | Select-Object -Skip 1) | ForEach-Object { " $_ | Change |" }) -join '')
    $sep    = "|---|---|" + ((@($Versions | Select-Object -Skip 1) | ForEach-Object { "---|---|" }) -join '')

    foreach ($metric in @(
        # p50 first: it is the steadiest statistic run to run, so it resolves
        # version differences that p95/p99 need many more runs to show.
        @{ Title = 'p50 (ms)'; Value = 'P50'; Spread = 'P50Std' },
        @{ Title = 'p95 (ms)'; Value = 'P95'; Spread = 'P95Std' },
        @{ Title = 'p99 (ms)'; Value = 'P99'; Spread = 'P99Std' },
        @{ Title = 'Fastest request (ms)'; Value = 'Min'; Spread = 'MinStd'
           Note  = "The latency floor: network plus a cached response. It should be near-identical across versions. If it differs, either the runs were not made under the same conditions or every request got slower by a fixed amount, and the tables above carry that offset - re-run a version with known numbers as a control before drawing conclusions. The floor counts failed requests too, so a sampler with errors can show an unusually low value from an instant failure; check the error table first." }
    )) {
        [void]$out.AppendLine("## $($metric.Title)")
        [void]$out.AppendLine()
        if ($metric.Note) {
            [void]$out.AppendLine("> *$($metric.Note)*")
            [void]$out.AppendLine()
        }
        [void]$out.AppendLine($header)
        [void]$out.AppendLine($sep)
        foreach ($label in $labels) {
            $row  = "| ``$label`` |"
            $ref  = $reference.ByLabel[$label]
            for ($i = 0; $i -lt $sides.Count; $i++) {
                $s = $sides[$i].ByLabel[$label]
                if (-not $s) {
                    $row += $(if ($i -eq 0) { " - |" } else { " - | - |" })
                    continue
                }
                $value = $s.($metric.Value)
                $cell  = if ($s.LatencyRunCount -gt 1) { "$value ±$($s.($metric.Spread))" } else { "$value" }
                # Latency rests on fewer runs than were counted: say how many.
                # '!' = every run was over the error limit, so this is the
                # latency of failing runs (see the note at the top).
                if ($s.AllOverLimit) { $cell += " !" }
                elseif ($s.LatencyRunCount -lt $s.RunCount) { $cell += " (n=$($s.LatencyRunCount))" }
                # Judged per cell against the reference, so a version on the
                # same load keeps its change and only the odd one loses it.
                $otherLoad = $i -gt 0 -and $ref -and $s.LoadKey -ne $ref.LoadKey
                if ($otherLoad) { $cell += " *" }
                # The latency of failing runs is not comparable to anything:
                # instant failures are fast, so a change against it would read
                # as a large speed-up for the version that broke. Either side
                # being all-over-limit means no change is computed.
                $failingLatency = $i -gt 0 -and ($s.AllOverLimit -or ($ref -and $ref.AllOverLimit))
                $row  += " $cell |"
                if ($i -gt 0) {
                    $row += $(if (-not $ref) { " - |" }
                              elseif ($otherLoad -or $failingLatency) { " n/c |" }
                              else { " $(Format-VersionChange $ref.($metric.Value) $value $ref.($metric.Spread) $s.($metric.Spread) $SignificantDeltaPercent) |" })
                }
            }
            [void]$out.AppendLine($row)
        }
        [void]$out.AppendLine()
    }

    [void]$out.AppendLine("## Error rate (%) and runs counted")
    [void]$out.AppendLine()
    [void]$out.AppendLine("| Sampler | " + ($Versions -join ' | ') + " |")
    [void]$out.AppendLine("|---|" + ((@($Versions) | ForEach-Object { "---|" }) -join ''))
    foreach ($label in $labels) {
        $ref = $reference.ByLabel[$label]
        $rowCells = foreach ($side in $sides) {
            $s = $side.ByLabel[$label]
            if (-not $s) { '-' }
            else {
                $over = $s.RunCount - $s.LatencyRunCount
                $n    = if ($over -gt 0) { "n=$($s.RunCount), $over over limit" } else { "n=$($s.RunCount)" }
                $worst = if ($s.ErrMaxPct -gt $s.ErrPct) { "worst $($s.ErrMaxPct)%, " } else { '' }
                "$($s.ErrPct)% ($worst$n)$(if ($ref -and $s.LoadKey -ne $ref.LoadKey) { ' *' })"
            }
        }
        [void]$out.AppendLine("| ``$label`` | " + ($rowCells -join ' | ') + " |")
    }
    [void]$out.AppendLine()
    [void]$out.AppendLine("> *Each cell is the median of that sampler's per-run value, so p95 here is a median of per-run p95s. No all-sampler aggregate row: true aggregate percentiles need raw samples, which the history summary doesn't keep. The error rate is a median too, which hides failures in fewer than half the runs - ``worst`` is the highest single run and is shown whenever it is above the median. A fast sampler with a high error rate is not a win - read the error table before the latency ones.*")

    Write-Report $out.ToString()
    return
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
        -Major $Major `
        -OnlyRunIds $RunIds -Since $Since -ExcludeRunIds $ExcludeRunIds

    if ($cells.Count -eq 0) {
        Write-PipelineError "No history rows found for scenario '$Scenario'$(if ($Major) { " (major $Major)" }). Nothing to compare."
    }

    $baseline  = Get-HistoryStats -Cells $cells -Version $baselineVersion  -Tier $baselineTier  -Aggregate $Aggregate -Window $Window -MaxErrorRate $MaxErrorRate
    $candidate = Get-HistoryStats -Cells $cells -Version $candidateVersion -Tier $candidateTier -Aggregate $Aggregate -Window $Window -MaxErrorRate $MaxErrorRate

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
    $aggDescBaseline  = if ($Aggregate -eq 'median') { "median across $($baseline.Runs.Count) run(s)" }  else { "latest run" }
    $aggDescCandidate = if ($Aggregate -eq 'median') { "median across $($candidate.Runs.Count) run(s)" } else { "latest run" }
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
if ($isHistoryMode) {
    Add-LoadMismatchWarning -Out $out -Mismatches @(Get-LoadMismatches -Sides @($baseline, $candidate) -Labels @($BaselineLabel, $CandidateLabel))
    Add-SetupMismatchWarning -Out $out -Sides @($baseline, $candidate) -Labels @($BaselineLabel, $CandidateLabel) -PresetOnly:([bool]$isTierPair)
    Add-ExclusionNotes -Out $out -Sides @($baseline, $candidate) -Labels @($BaselineLabel, $CandidateLabel)
}

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
    # Every run of this sampler went over -MaxErrorRate on one side: its latency
    # is that of failing requests, which are fast, so a change would read as a
    # speed-up for the side that broke. Same rule as the -Versions tables.
    # (CSV-mode stats carry no AllOverLimit, so this is never true there.)
    if ($b.AllOverLimit -or $c.AllOverLimit) {
        $bCount = "$($b.Count)$(if ($b.AllOverLimit) { ' !' })"
        $cCount = "$($c.Count)$(if ($c.AllOverLimit) { ' !' })"
        [void]$out.AppendLine("| ``$label`` | $bCount | $cCount | n/c | n/c | n/c |")
        $anyFailingSampler = $true
        continue
    }
    [void]$out.AppendLine("| ``$label`` | $($b.Count) | $($c.Count) | $(Format-Cell $b.Avg $c.Avg $SignificantDeltaPercent) | $(Format-Cell $b.P95 $c.P95 $SignificantDeltaPercent) | $(Format-Cell $b.P99 $c.P99 $SignificantDeltaPercent) |")
}
if ($anyFailingSampler) {
    [void]$out.AppendLine()
    [void]$out.AppendLine("``!`` = every run of that sampler went over the $MaxErrorRate% error limit on that side, so no latency change is computed (``n/c``). The errors are the result there.")
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

Write-Report $out.ToString()
