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
#   # several versions side by side on a fixed tier (first one is the reference)
#   ./scripts/compare-runs.ps1 -Scenario Default -Tier Starter `
#       -Versions 17.6.1,18.0.0,19.0.0-beta1 -Aggregate median5 `
#       -HistoryResourceGroup umbraco-loadtest-history-rg `
#       -StorageAccountName loadtesthistory -ContainerName loadtest-history
#
#   Aggregate mode: 'latest' (default) takes the most recent run per cell;
#   'median5' takes the median across the last 5 runs (more stable on noisy tails).
#   Either way a cell only counts runs that drove the same load as its newest
#   run, and the report warns when the two sides drove different loads.
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

    [ValidateSet('latest', 'median5')] [string]$Aggregate = 'latest',

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
        # Select-LikeForLikeRuns (from _history-helpers.ps1, dot-sourced before
        # this function runs) sorts newest-first and keeps only runs that drove
        # the same load as the newest one, so 'median5' can't fold a smoke or
        # ramp run in with the standard runs around it.
        $window = if ($Aggregate -eq 'latest') { 1 } else { 5 }
        $picked = @(Select-LikeForLikeRuns -Runs @($Cells[$cellKey]) -First $window)
        if ($picked.Count -eq 0) { continue }

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
            # Fastest request per run: the latency floor (network + a cached
            # response). It barely moves with the code under test, so a shift
            # here points at the environment rather than the version.
            Min      = [int][math]::Round((Get-Median (@($picked | ForEach-Object { [double]$_.min_ms }))), 0)
            ErrPct   = [math]::Round((Get-Median (@($picked | ForEach-Object { [double]$_.error_rate }))) * 100, 2)
            # Run-to-run spread of each latency median, for the multi-version table.
            P50Std   = [int][math]::Round((Get-PopulationStdDev (@($picked | ForEach-Object { [double]$_.p50_ms }))), 0)
            P95Std   = [int][math]::Round((Get-PopulationStdDev (@($picked | ForEach-Object { [double]$_.p95_ms }))), 0)
            P99Std   = [int][math]::Round((Get-PopulationStdDev (@($picked | ForEach-Object { [double]$_.p99_ms }))), 0)
            LoadKey  = Get-LoadKey $picked[0]
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
    [void]$Out.AppendLine("> **Load mismatch - the rows below are not like-for-like.** The picked runs drove different loads, so their deltas reflect the load, not the version/tier. Re-run the odd side at the same profile before reading them.")
    foreach ($m in $Mismatches) {
        [void]$Out.AppendLine("> - ``$($m.Sampler)`` - $($m.Detail)")
    }
    [void]$Out.AppendLine()
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
        -Major $Major

    if ($cells.Count -eq 0) {
        Write-PipelineError "No history rows found for scenario '$Scenario'$(if ($Major) { " (major $Major)" }). Nothing to compare."
    }

    $sides = @(foreach ($v in $Versions) {
        $stats = Get-HistoryStats -Cells $cells -Version $v -Tier $Tier -Aggregate $Aggregate
        if ($stats.ByLabel.Count -eq 0) {
            Write-PipelineError "No history rows for cell ($v / $Tier / $Scenario). Version strings are matched exactly - has this combination ever run?$(if ($Major) { " -Major $Major also limits the search to that major; drop it when comparing across majors." })"
        }
        $stats
    })

    $reference  = $sides[0]
    $mismatches = @(Get-LoadMismatches -Sides $sides -Labels $Versions)
    $mismatched = @($mismatches | ForEach-Object { $_.Sampler })

    $out = New-Object System.Text.StringBuilder
    [void]$out.AppendLine("# Version comparison on ${Tier}: $($Versions -join ' / ')")
    [void]$out.AppendLine()
    [void]$out.AppendLine("- Source: history storage (``$StorageAccountName/$ContainerName``), scenario ``$Scenario``")
    [void]$out.AppendLine("- Aggregate: $(if ($Aggregate -eq 'median5') { 'median across the last 5 like-for-like runs per sampler (fewer when fewer exist)' } else { 'latest run per sampler' })")
    for ($i = 0; $i -lt $Versions.Count; $i++) {
        $runs    = @($sides[$i].Runs)
        $ids     = (@($runs | ForEach-Object { "#$($_.run_id)" }) -join ', ')
        $loads   = (@($sides[$i].ByLabel.Values | ForEach-Object { $_.LoadKey } | Sort-Object -Unique | ForEach-Object { Format-LoadKey $_ }) -join ' / ')
        $dotnet  = (@($runs | ForEach-Object { [string]$_.dotnet_version } | Where-Object { $_ } | Sort-Object -Unique) -join ', ')
        $commits = (@($runs | ForEach-Object { $c = [string]$_.commit; if ($c.Length -gt 7) { $c.Substring(0, 7) } else { $c } } | Where-Object { $_ } | Sort-Object -Unique) -join ', ')
        # Seeded content as the runs themselves reported it. More than one value
        # per field means the runs behind this version did not hold the same content.
        $seeded = (@(
            @{ Label = 'content';      Field = 'seeded_content_total' },
            @{ Label = 'media images'; Field = 'seeded_media_images' },
            @{ Label = 'media files';  Field = 'seeded_media_files' }
        ) | ForEach-Object {
            $field  = $_.Field
            $values = @($runs | ForEach-Object { $_.$field } | Where-Object { $null -ne $_ -and "$_" -ne '' } | Sort-Object -Unique)
            if ($values.Count -gt 0) { "$($_.Label) $($values -join '/')" }
        }) -join ', '
        if (-not $seeded) { $seeded = 'not recorded' }
        [void]$out.AppendLine("- **$($Versions[$i])**: $($runs.Count) run(s) ($ids); load: $loads; .NET $dotnet; harness commit(s) $commits; seeded: $seeded")
    }
    [void]$out.AppendLine("- Change columns are relative to **$($Versions[0])**; bold = at or above $SignificantDeltaPercent%. Negative = faster.")
    [void]$out.AppendLine("- ``±`` is the run-to-run standard deviation of the value beside it (shown when a cell has 2+ runs). A change smaller than the spread is noise.")
    [void]$out.AppendLine()
    Add-LoadMismatchWarning -Out $out -Mismatches $mismatches

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
        @{ Title = 'Fastest request (ms)'; Value = 'Min'; Spread = $null
           Note  = "The latency floor: network plus a cached response. It should be near-identical across versions. If it differs, the runs were not made under the same conditions (or every request got slower by a fixed amount) and the tables above carry that offset - re-run a version with known numbers as a control before drawing conclusions." }
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
            $name = if ($mismatched -contains $label) { "``$label`` (load differs)" } else { "``$label``" }
            $row  = "| $name |"
            $ref  = $reference.ByLabel[$label]
            for ($i = 0; $i -lt $sides.Count; $i++) {
                $s = $sides[$i].ByLabel[$label]
                if (-not $s) {
                    $row += $(if ($i -eq 0) { " - |" } else { " - | - |" })
                    continue
                }
                $value = $s.($metric.Value)
                $cell  = if ($metric.Spread -and $s.RunCount -gt 1) { "$value ±$($s.($metric.Spread))" } else { "$value" }
                $row  += " $cell |"
                if ($i -gt 0) {
                    $row += $(if ($ref) { " $(Format-Cell $ref.($metric.Value) $value $SignificantDeltaPercent) |" } else { " - |" })
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
        $rowCells = foreach ($side in $sides) {
            $s = $side.ByLabel[$label]
            if ($s) { "$($s.ErrPct)% (n=$($s.RunCount))" } else { '-' }
        }
        [void]$out.AppendLine("| ``$label`` | " + ($rowCells -join ' | ') + " |")
    }
    [void]$out.AppendLine()
    [void]$out.AppendLine("> *Each cell is the median of that sampler's per-run value, so p95 here is a median of per-run p95s. No all-sampler aggregate row: true aggregate percentiles need raw samples, which the history summary doesn't keep. A fast sampler with a high error rate is not a win - read the error table before the latency ones.*")

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
if ($isHistoryMode) {
    Add-LoadMismatchWarning -Out $out -Mismatches @(Get-LoadMismatches -Sides @($baseline, $candidate) -Labels @($BaselineLabel, $CandidateLabel))
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

Write-Report $out.ToString()
