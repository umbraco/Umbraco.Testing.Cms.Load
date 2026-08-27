#requires -Version 7.3

# Compare one run for each (version, tier, sampler) cell against the median of
# the previous N runs and flag regressions exceeding configurable thresholds.
# Exits non-zero when any cell regresses (default), making this safe to wire
# into the pipeline as a post-load-test gate once baselines exist.
#
# Pass -RunId to pin which run is graded; the pipeline always does.
#
# A cell with fewer than -MinBaselineRuns prior runs is reported as "insufficient
# baseline" and never contributes to a fail — you can't regress against nothing.
#
# Usage (run `az login` first):
#   ./scripts/check-regression.ps1 -Scenario Default `
#       -HistoryResourceGroup umbraco-loadtest-history-rg `
#       -StorageAccountName loadtesthistory -ContainerName loadtest-history
#
#   # CI-friendly (non-zero exit on regression), gating a specific run:
#   ./scripts/check-regression.ps1 ... -RunId 12345 -OutputPath regression-report.md
#
#   # Tighter thresholds for a release-gate run:
#   ./scripts/check-regression.ps1 ... -P95Threshold 5 -P99Threshold 10

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)] [string]$Scenario,
    [Parameter(Mandatory = $true)] [string]$HistoryResourceGroup,
    [Parameter(Mandatory = $true)] [string]$StorageAccountName,
    [Parameter(Mandatory = $true)] [string]$ContainerName,

    [string]$Major,
    [string]$Sampler,
    [string]$OutputPath,

    # Pins the run being gated. Unset = "newest row wins", which is a DIFFERENT
    # run whenever this one's publish failed (continueOnError) - fine for ad-hoc
    # analysis, wrong for a gate.
    [string]$RunId,

    # Percentage thresholds: latest > baseline-median * (1 + threshold/100) is a regression.
    # p99 gets a wider band because tail latency is noisier than p95 by nature.
    [double]$P95Threshold = 10,
    [double]$P99Threshold = 15,

    # Absolute percentage-point delta on error_rate. A jump from 0% to 0.5% is meaningful;
    # a jump from 5% to 5.4% is noise.
    [double]$ErrorAbsoluteThreshold = 0.5,

    # Number of prior runs required before a cell is gateable.
    [int]$MinBaselineRuns = 3,

    # Cap on how many prior runs feed the baseline median (keeps trend sensitive
    # to recent state — old runs from a different code era shouldn't anchor today).
    [int]$BaselineWindow = 5,

    # Set the switch to render the report without failing the script even when
    # regressions are found (useful for "show me what would break"). The default
    # behaviour is to fail on regression; using a [switch] avoids a footgun where
    # passing -FailOnRegression "false" as a string is silently truthy.
    [switch]$NoFailOnRegression,

    # Optional Logs Ingestion API target. When all three are provided, the
    # script POSTs one status row per (run_id × scenario × version × tier) to
    # the same custom table that publish-load-test-results.ps1 writes to. The
    # Workbook joins these rows back to the load-test rows by run_id to surface
    # regression status alongside the run. Empty (default) skips the post.
    [string]$LogAnalyticsDceUri,
    [string]$LogAnalyticsDcrImmutableId,
    [string]$LogAnalyticsStreamName
)

$ErrorActionPreference = "Stop"

# Make native commands (az CLI) honour $ErrorActionPreference. Requires pwsh 7.3+.
$PSNativeCommandUseErrorActionPreference = $true

. "$PSScriptRoot/_history-helpers.ps1"

# --- Load history ---

$cells = Get-HistoryCells `
    -Scenario $Scenario `
    -HistoryResourceGroup $HistoryResourceGroup `
    -StorageAccountName $StorageAccountName `
    -ContainerName $ContainerName `
    -Major $Major `
    -Sampler $Sampler

if ($cells.Count -eq 0) {
    Write-Warning "No metric rows matched the filter - nothing to check."
    if ($OutputPath) {
        # Always write the file so the pipeline's PublishBuildArtifacts step has
        # something to upload — first-ever runs have no history to compare against.
        @"
# Regression check - scenario: $Scenario$(if ($Major) { " (major $Major)" })

No history found for this scenario yet — nothing to compare against. This is
expected on the first run for a fresh scenario; subsequent runs will populate
history and the gate will activate per cell as baselines accrue.
"@ | Out-File -FilePath $OutputPath -Encoding utf8
    }
    exit 0
}

# Defensively drop rows whose run_started_at won't parse, using Get-RunDate
# from _history-helpers.ps1 (dot-sourced above). A single corrupt timestamp
# would otherwise throw under $ErrorActionPreference="Stop" during the
# Sort-Object below and brick every future regression check until the bad
# blob is manually pruned.
$droppedRows = 0
# Snapshot keys via @(...) so $cells.Remove() inside the loop doesn't mutate
# the enumerator we're iterating.
foreach ($cellKey in @($cells.Keys)) {
    $valid = @($cells[$cellKey] | Where-Object { $null -ne (Get-RunDate $_) })
    $droppedRows += ($cells[$cellKey].Count - $valid.Count)
    if ($valid.Count -eq 0) {
        $cells.Remove($cellKey)
    } else {
        $cells[$cellKey] = $valid
    }
}
if ($droppedRows -gt 0) {
    Write-Warning "Dropped $droppedRows row(s) with unparseable run_started_at from history (kept the rest)."
}
if ($cells.Count -eq 0) {
    # Don't fall through to the "PASS - 0 stable, 0 improvements" report; that
    # would silently green-light a run whose entire history is corrupt. Distinguish
    # from the empty-history case above (which exits 0) because that's a legitimate
    # first-ever-run state, but ALL rows failing to parse is data corruption.
    Write-PipelineError "Every history row failed to parse (dropped $droppedRows row(s)). Manual storage cleanup required before regression check can resume."
}

# --- Compare latest vs baseline-median per cell ---

$regressions  = @()
$improvements = @()
$stable       = @()
$insufficient = @()
$missing      = @()

# Reused by the Log Analytics block below, so it can't re-sort and disagree.
$candidateByCell = @{}

foreach ($cellKey in $cells.Keys) {
    $sorted = @($cells[$cellKey] |
        Sort-Object { Get-RunDate $_ } -Descending)

    # Limit 3 so sampler names that legally contain '__' (e.g. a future
    # task like 'Backoffice__SavePublish') don't get truncated into a wrong
    # cell. _history-helpers.ps1's cellKey builder uses three fields and
    # Get-HistoryStats also splits with -split '__', 3 — match that.
    $parts   = $cellKey -split '__', 3
    $version = $parts[0]
    $tier    = $parts[1]
    $samp    = $parts[2]

    # Index, not just the row, so the baseline below can be "older than the
    # candidate" even when the candidate isn't the newest row.
    $candIndex = if ($RunId) { [array]::FindIndex([object[]]$sorted, [Predicate[object]]{ [string]$args[0].run_id -eq $RunId }) } else { 0 }
    if ($candIndex -lt 0) {
        # This run published nothing for this cell. Grading the newest OTHER row
        # would report a verdict for a run nobody asked about. Plan = the .jmx
        # stem, used below to tell a skipped plan from a partial publish.
        $missing += [pscustomobject]@{
            Version = $version; Tier = $tier; Sampler = $samp
            Plan    = Get-PlanName $samp
        }
        continue
    }
    $candidate = $sorted[$candIndex]
    $candidateByCell[$cellKey] = $candidate

    # Like-for-like baseline: a run only compares against PRIOR runs that drove
    # the SAME load — same VU count, spawn rate, and duration. This keeps a ramp
    # run (climbing 0->target, spawn 1) out of the steady baseline, AND stops a
    # 15-VU backoffice run from comparing against 50-VU history (same profile
    # name, different load = meaningless delta). A new load just yields
    # "insufficient history" until same-load baselines accrue — the correct
    # verdict, not a false regression. (Profile/load isn't a stored key; this
    # matches the actual published load params, which every metric row carries.)
    # "Prior" = later in the descending sort, so a pinned candidate compares only
    # against runs older than itself.
    $candLoad      = "$($candidate.user_count)|$($candidate.spawn_rate)|$($candidate.duration_seconds)"
    $older         = @($sorted | Select-Object -Skip ($candIndex + 1))
    $priorRuns     = @($older |
        Where-Object { "$($_.user_count)|$($_.spawn_rate)|$($_.duration_seconds)" -eq $candLoad } |
        Select-Object -First $BaselineWindow)
    $priorRunCount = $priorRuns.Count

    if ($priorRunCount -lt $MinBaselineRuns) {
        $insufficient += [pscustomobject]@{
            Version       = $version
            Tier          = $tier
            Sampler       = $samp
            PriorRunCount = $priorRunCount
            Required      = $MinBaselineRuns
        }
        continue
    }

    $basP95 = Get-Median (@($priorRuns | ForEach-Object { [double]$_.p95_ms }))
    $basP99 = Get-Median (@($priorRuns | ForEach-Object { [double]$_.p99_ms }))
    $basErr = Get-Median (@($priorRuns | ForEach-Object { [double]$_.error_rate }))

    $candP95 = [double]$candidate.p95_ms
    $candP99 = [double]$candidate.p99_ms
    $candErr = [double]$candidate.error_rate

    # Avoid divide-by-zero when baseline is 0; treat any positive candidate as +inf%.
    $deltaP95Pct = if ($basP95 -gt 0) { ($candP95 - $basP95) / $basP95 * 100 } elseif ($candP95 -gt 0) { [double]::PositiveInfinity } else { 0 }
    $deltaP99Pct = if ($basP99 -gt 0) { ($candP99 - $basP99) / $basP99 * 100 } elseif ($candP99 -gt 0) { [double]::PositiveInfinity } else { 0 }
    $deltaErrPP  = ($candErr - $basErr) * 100

    $cellReport = [pscustomobject]@{
        Version       = $version
        Tier          = $tier
        Sampler       = $samp
        PriorRunCount = $priorRunCount
        BaselineP95   = [int][math]::Round($basP95, 0)
        BaselineP99   = [int][math]::Round($basP99, 0)
        BaselineErr   = [math]::Round($basErr * 100, 2)
        CandidateP95  = [int][math]::Round($candP95, 0)
        CandidateP99  = [int][math]::Round($candP99, 0)
        CandidateErr  = [math]::Round($candErr * 100, 2)
        DeltaP95Pct   = [math]::Round($deltaP95Pct, 1)
        DeltaP99Pct   = [math]::Round($deltaP99Pct, 1)
        DeltaErrPP    = [math]::Round($deltaErrPP, 2)
    }

    $isRegression = ($deltaP95Pct -gt $P95Threshold) -or
                    ($deltaP99Pct -gt $P99Threshold) -or
                    ($deltaErrPP  -gt $ErrorAbsoluteThreshold)

    # An "improvement" is the mirror of a regression — significant negative delta on p95.
    # We don't try to be clever about p99 improvements (too noisy to call definitively).
    $isImprovement = ($deltaP95Pct -lt -$P95Threshold)

    if     ($isRegression)  { $regressions  += $cellReport }
    elseif ($isImprovement) { $improvements += $cellReport }
    else                    { $stable       += $cellReport }
}

# --- Render markdown report ---

$out = New-Object System.Text.StringBuilder
[void]$out.AppendLine("# Regression check - scenario: $Scenario$(if ($Major) { " (major $Major)" })")
[void]$out.AppendLine()
[void]$out.AppendLine("**Thresholds:** p95 +${P95Threshold}%, p99 +${P99Threshold}%, error_rate +${ErrorAbsoluteThreshold}pp absolute. Baseline window: last $BaselineWindow runs (min $MinBaselineRuns required).")
[void]$out.AppendLine()
# Name the graded run - a report that doesn't say which run it judged is no use.
if ($RunId) {
    [void]$out.AppendLine("**Candidate run:** ``$RunId`` (cells with no row for this run are listed under 'Candidate missing').")
} else {
    [void]$out.AppendLine("**Candidate run:** newest row per cell (no -RunId pinned - ad-hoc mode).")
}
[void]$out.AppendLine()
[void]$out.AppendLine("**Result:** $($regressions.Count) regressions, $($improvements.Count) improvements, $($stable.Count) stable, $($insufficient.Count) cells skipped (insufficient baseline), $($missing.Count) cells with no candidate row.")
[void]$out.AppendLine()

function Add-CellTable {
    param([System.Text.StringBuilder] $sb, [object[]] $rows, [string] $title)
    if ($rows.Count -eq 0) { return }
    [void]$sb.AppendLine("## $title")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("| Version | Tier | Sampler | Baseline p95 / p99 / err (n) | Latest p95 / p99 / err | Delta p95 | Delta p99 | Delta err |")
    [void]$sb.AppendLine("|---|---|---|---|---|---|---|---|")
    $ordered = $rows | Sort-Object Sampler, Version, Tier
    foreach ($c in $ordered) {
        $bas  = "$($c.BaselineP95) / $($c.BaselineP99) / $($c.BaselineErr)% (n=$($c.PriorRunCount))"
        $cand = "$($c.CandidateP95) / $($c.CandidateP99) / $($c.CandidateErr)%"
        # PositiveInfinity (baseline 0, candidate positive) formats as a bogus
        # "8%" under the composite format string — render it as "new" instead.
        $dp95 = if ([double]::IsInfinity($c.DeltaP95Pct)) { 'new' } else { "{0:+0.0;-0.0;0.0}%" -f $c.DeltaP95Pct }
        $dp99 = if ([double]::IsInfinity($c.DeltaP99Pct)) { 'new' } else { "{0:+0.0;-0.0;0.0}%" -f $c.DeltaP99Pct }
        $derr = "{0:+0.00;-0.00;0.00}pp" -f $c.DeltaErrPP
        [void]$sb.AppendLine("| $($c.Version) | $($c.Tier) | $($c.Sampler) | $bas | $cand | $dp95 | $dp99 | $derr |")
    }
    [void]$sb.AppendLine()
}

Add-CellTable -sb $out -rows $regressions  -title "Regressions"
Add-CellTable -sb $out -rows $improvements -title "Improvements"
Add-CellTable -sb $out -rows $stable       -title "Stable (within thresholds)"

if ($insufficient.Count -gt 0) {
    [void]$out.AppendLine("## Insufficient baseline (need >= $MinBaselineRuns prior runs)")
    [void]$out.AppendLine()
    foreach ($c in ($insufficient | Sort-Object Sampler, Version, Tier)) {
        [void]$out.AppendLine("- $($c.Version) / $($c.Tier) / $($c.Sampler) (only $($c.PriorRunCount) prior run(s))")
    }
    [void]$out.AppendLine()
}

# A whole absent plan means it wasn't queued this run - backofficePlans trimmed
# it, or workload picked the other side (frontend XOR backoffice, never both,
# per azure-pipeline.yml) - expected, so it must not warn. A partial absence is
# the publish anomaly -RunId exists to catch.
$missingPartialPlans = @()
if ($missing.Count -gt 0) {
    # Scope $cellsPerPlan to (version, tier) combos this run actually covers -
    # else a single-tier run counts every other tier's cells as "missing" too.
    $runVersionTiers = @{}
    foreach ($cellKey in $candidateByCell.Keys) {
        $p = $cellKey -split '__', 3
        $runVersionTiers["$($p[0])__$($p[1])"] = $true
    }
    $cellsPerPlan = @{}
    foreach ($k in $cells.Keys) {
        $parts = $k -split '__', 3
        if ($runVersionTiers.Count -gt 0 -and -not $runVersionTiers.ContainsKey("$($parts[0])__$($parts[1])")) { continue }
        $p = Get-PlanName $parts[2]
        $cellsPerPlan[$p] = 1 + [int]$cellsPerPlan[$p]
    }
    $publishedNone = ($missing.Count -ge $cells.Keys.Count)

    [void]$out.AppendLine("## Candidate missing (no row for run ``$RunId``)")
    [void]$out.AppendLine()
    if ($publishedNone) {
        # Not necessarily a failure: Get-HistoryCells drops cold_start rows, so a
        # skipWarmup run has every row filtered out even though it published fine.
        [void]$out.AppendLine("**No rows from this run matched** any of the $($cells.Keys.Count) cell(s) in history. Either the run published nothing (check the loadTest stage), or its rows were filtered out - a ``skipWarmup`` run is excluded from comparison because every row is flagged ``cold_start``.")
        [void]$out.AppendLine()
    }
    foreach ($grp in ($missing | Group-Object Plan | Sort-Object Name)) {
        $total     = $cellsPerPlan[$grp.Name]
        $wholePlan = ($grp.Count -ge $total)
        if ($wholePlan -and -not $publishedNone) {
            [void]$out.AppendLine("- **$($grp.Name)**: all $total cell(s) absent - this plan didn't run (trimmed from ``backofficePlans``, or no .jmx for this major). Expected.")
            continue
        }
        $missingPartialPlans += $grp.Name
        $why = if ($wholePlan) { "all $total" } else { "$($grp.Count) of $total" }
        [void]$out.AppendLine("- **$($grp.Name)**: $why cell(s) absent - this run didn't publish them. Check the publish step.")
        foreach ($c in ($grp.Group | Sort-Object Sampler, Version, Tier)) {
            [void]$out.AppendLine("  - $($c.Version) / $($c.Tier) / $($c.Sampler)")
        }
    }
    [void]$out.AppendLine()
}

$report = $out.ToString()

if ($OutputPath) {
    $report | Out-File -FilePath $OutputPath -Encoding utf8
    Write-Host "Report written to: $OutputPath"
}

# Always print a one-line summary; print full report when there are regressions
# so CI logs surface the failure detail without needing to open the artifact.
if ($regressions.Count -gt 0) {
    Write-Host ""
    Write-Host $report
    Write-Host "##vso[task.logissue type=error]$($regressions.Count) regression(s) detected against baseline."
    $exitOnRegression = -not $NoFailOnRegression
} else {
    Write-Host ""
    Write-Host "PASS - no regressions ($($stable.Count) stable, $($improvements.Count) improvements, $($insufficient.Count) cells skipped for insufficient baseline)."
    $exitOnRegression = $false
}

# A pinned run that published nothing for cells with existing history is a
# publish-side problem, not a perf verdict — warn rather than fail, but don't let
# it pass silently (that silence is what made the un-pinned gate misleading).
# Partial absences only - see the classification above.
if ($RunId -and $missingPartialPlans.Count -gt 0) {
    Write-Host "##vso[task.logissue type=warning]No comparable rows from run '$RunId' for: $($missingPartialPlans -join ', '). Either the publish step didn't land every cell, or the rows were filtered (a skipWarmup run is excluded as cold_start). See 'Candidate missing' in the report."
}
elseif ($RunId -and $missing.Count -gt 0) {
    Write-Host "$($missing.Count) cell(s) with history had no row for run '$RunId', all accounted for by plans that didn't run in this queue. See 'Candidate missing' in the report."
}

# Post regression-check status to Log Analytics. One row per (run_id × scenario
# × version × tier) — aggregated up from the per-sampler cell results so the
# Workbook can join them to load-test rows by run_id. parse_status =
# 'regression_check' marks the row type so the Workbook's load-test queries
# can filter it out cleanly.
#
# Same defensive posture as publish-load-test-results.ps1: failure here warns
# and continues (the gate's pass/fail and the build artifact remain authoritative;
# this is the queryable mirror).
if ($LogAnalyticsDceUri -and $LogAnalyticsDcrImmutableId -and $LogAnalyticsStreamName) {
    # Re-walk the cells with both their candidate run row and computed verdict.
    # $regressions / $improvements / $stable / $insufficient have summary fields
    # but not the candidate's run_id / scenario, so we look those up here.
    $regSet  = @{}
    $insufSet = @{}
    foreach ($r in $regressions)  { $regSet["$($r.Version)__$($r.Tier)__$($r.Sampler)"] = $true }
    foreach ($r in $insufficient) { $insufSet["$($r.Version)__$($r.Tier)__$($r.Sampler)"] = $true }

    $statusByGroup = @{}   # key: run_id|scenario|version|tier
    # The candidates the grading loop chose - re-deriving them here would both
    # re-sort every cell and risk disagreeing with the graded verdict.
    foreach ($cellKey in $candidateByCell.Keys) {
        $candidate = $candidateByCell[$cellKey]
        $parts     = $cellKey -split '__', 3
        $version   = $parts[0]
        $tier      = $parts[1]
        $samp      = $parts[2]

        $isReg   = $regSet.ContainsKey($cellKey)
        $isInsuf = $insufSet.ContainsKey($cellKey)

        $groupKey = "$($candidate.run_id)|$($candidate.scenario)|$version|$tier"
        if (-not $statusByGroup.ContainsKey($groupKey)) {
            $statusByGroup[$groupKey] = [pscustomobject]@{
                run_id              = $candidate.run_id
                scenario            = $candidate.scenario
                umbraco_version     = $version
                infra_tier          = $tier
                regressed_samplers  = New-Object System.Collections.Generic.List[string]
                insufficient_count  = 0
                checked_count       = 0
            }
        }
        $g = $statusByGroup[$groupKey]
        $g.checked_count++
        if ($isReg)   { $g.regressed_samplers.Add($samp) }
        if ($isInsuf) { $g.insufficient_count++ }
    }

    if ($statusByGroup.Count -gt 0) {
        $now = (Get-Date).ToUniversalTime().ToString("o")
        $rows = foreach ($g in $statusByGroup.Values) {
            $regressedList = ($g.regressed_samplers -join ',')
            $verdict =
                if ($g.regressed_samplers.Count -gt 0) { 'regress' }
                elseif ($g.insufficient_count -eq $g.checked_count) { 'insufficient' }
                else { 'pass' }
            [pscustomobject]@{
                TimeGenerated      = $now
                run_id             = [string]$g.run_id
                scenario           = [string]$g.scenario
                umbraco_version    = [string]$g.umbraco_version
                infra_tier         = [string]$g.infra_tier
                parse_status       = 'regression_check'
                regression_status  = $verdict
                regressed_samplers = $regressedList
                regressed_count    = $g.regressed_samplers.Count
            }
        }

        Write-Host ""
        Write-Host "Posting $($rows.Count) regression-status row(s) to Log Analytics ($LogAnalyticsStreamName)"
        try {
            $token = az account get-access-token --resource https://monitor.azure.com --query accessToken -o tsv
            $body  = ConvertTo-Json -InputObject @($rows) -Depth 5 -Compress -AsArray
            $url   = "$LogAnalyticsDceUri/dataCollectionRules/$LogAnalyticsDcrImmutableId/streams/${LogAnalyticsStreamName}?api-version=2023-01-01"
            Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType "application/json" `
                -Headers @{ Authorization = "Bearer $token" } | Out-Null
            Write-Host "   ok"
        }
        catch {
            $msg = "Regression-status ingestion failed: $($_.Exception.Message). Build artifact ($OutputPath) remains authoritative."
            Write-Warning $msg
            Write-Host "##vso[task.logissue type=warning]$msg"
        }
    }
}

if ($exitOnRegression) { exit 1 }
