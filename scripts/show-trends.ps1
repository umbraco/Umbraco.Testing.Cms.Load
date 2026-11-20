#requires -Version 7.3

# Print a (version × tier) matrix of p95/p99/error% for one scenario by reading
# every summary.ndjson under that scenario's history-storage prefix.
#
# Cells: latest run when there's only one; median ± population stddev plus a
# run-count when there are 2+ runs. The stddev makes baseline stability visible
# (see "Establishing a baseline" in README).
#
# Usage (run `az login` first):
#   ./scripts/show-trends.ps1 -Scenario Default -Major 17 `
#       -HistoryResourceGroup umbraco-loadtest-history-rg `
#       -StorageAccountName loadtesthistory -ContainerName loadtest-history
#   ./scripts/show-trends.ps1 -Scenario Default -Sampler Detail -OutputPath trends.md

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)] [string]$Scenario,
    [Parameter(Mandatory = $true)] [string]$HistoryResourceGroup,
    [Parameter(Mandatory = $true)] [string]$StorageAccountName,
    [Parameter(Mandatory = $true)] [string]$ContainerName,

    [string]$Major,
    [string]$Sampler,
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"

# Make native commands (az CLI) honour $ErrorActionPreference. Requires pwsh 7.3+.
$PSNativeCommandUseErrorActionPreference = $true

. "$PSScriptRoot/_history-helpers.ps1"

# Load label for a cell, shown only when the cells of one table were measured
# under different loads. The full load key, not just VUs and duration: stress
# and ramp share both (300 VUs, 600 s) and differ only in spawn rate, and a
# methodology change shifts the numbers without changing the load at all.
function Get-CellLoad($allRuns) {
    $runs = @(Select-LikeForLikeRuns -Runs @($allRuns))
    if ($runs.Count -eq 0) { return $null }
    Format-LoadKey (Get-LoadKey $runs[0])
}

function Format-Cell($allRuns, [bool]$ShowLoad) {
    if (-not $allRuns -or $allRuns.Count -eq 0) { return '-' }

    # Only the runs that drove the same load as the cell's newest run: a smoke
    # or ramp run in the same cell would otherwise move the median and inflate
    # the stddev this matrix exists to show.
    $runs = @(Select-LikeForLikeRuns -Runs @($allRuns))
    $load = if ($ShowLoad) { " [$(Get-CellLoad $allRuns)]" } else { '' }

    # Median, not mean, to match the p95/p99 statistic in the same cell - a mean
    # let one bad run skew the figure the latencies beside it are protected from.
    $errPct = [math]::Round((Get-Median (@($runs | ForEach-Object { [double]$_.error_rate }))) * 100, 2)

    if ($runs.Count -eq 1) {
        $p95 = [int][math]::Round([double]$runs[0].p95_ms, 0)
        $p99 = [int][math]::Round([double]$runs[0].p99_ms, 0)
        return "$p95 / $p99 ($errPct%)$load"
    }

    $p95s = @($runs | ForEach-Object { [double]$_.p95_ms })
    $p99s = @($runs | ForEach-Object { [double]$_.p99_ms })

    $p95Med = [int][math]::Round((Get-Median $p95s), 0)
    $p99Med = [int][math]::Round((Get-Median $p99s), 0)
    $p95Std = [int][math]::Round((Get-PopulationStdDev $p95s), 0)
    $p99Std = [int][math]::Round((Get-PopulationStdDev $p99s), 0)

    return "$p95Med ±$p95Std / $p99Med ±$p99Std ($errPct%) n=$($runs.Count)$load"
}

# --- Load history ---

$cells = Get-HistoryCells `
    -Scenario $Scenario `
    -HistoryResourceGroup $HistoryResourceGroup `
    -StorageAccountName $StorageAccountName `
    -ContainerName $ContainerName `
    -Major $Major `
    -Sampler $Sampler

if ($cells.Count -eq 0) {
    Write-Warning "No metric rows matched the filter (Scenario=$Scenario, Sampler=$Sampler, Major=$Major)."
    return
}

# --- Discover dimensions from the data ---

# Version-aware sort: lexicographic ordering puts 17.0.10 before 17.0.2 and
# scrambles prereleases ('17.0.0-rc.1' before '17.0.0') — both wrong. Sort by
# (release-version, prerelease-suffix), using '~' as the sentinel for an empty
# suffix so release versions sort AFTER their prereleases (SemVer 2.0.0). The
# try/catch falls back to a neutral version for anything [version] can't parse.
$versions = @($cells.Values | ForEach-Object { $_[0].umbraco_version } | Sort-Object -Unique -Property `
    @{ Expression = { try { [version](($_ -split '-', 2)[0]) } catch { [version]'0.0.0' } } },
    @{ Expression = { $p = $_ -split '-', 2; if ($p.Count -lt 2) { '~' } else { $p[1] } } })
$tiers    = @($cells.Values | ForEach-Object { $_[0].infra_tier      } | Sort-Object -Unique)
$samplers = @($cells.Values | ForEach-Object { $_[0].scenario_name   } | Sort-Object -Unique)

# Stable tier ordering: known tiers first in their natural order, then anything else.
$tierOrder = @('Starter', 'Standard', 'Pro', 'Enterprise')
$tiers = @($tierOrder | Where-Object { $tiers -contains $_ }) +
         @($tiers | Where-Object { $tierOrder -notcontains $_ })

# --- Render ---

$prefix = Get-HistoryPrefix -Scenario $Scenario -Major $Major

$out = New-Object System.Text.StringBuilder
[void]$out.AppendLine("# Trends - scenario: $Scenario$(if ($Major) { " (major $Major)" })")
[void]$out.AppendLine()
[void]$out.AppendLine("Source: $StorageAccountName/$ContainerName/$prefix")
[void]$out.AppendLine("Cells are 'p95 / p99 (err%)' in ms for single-run cells; 'median ±stddev / median ±stddev (err%) n=K' when 2+ runs exist. err% is the median across runs, matching the latency statistic beside it.")
[void]$out.AppendLine("Each cell counts only the runs that drove the same load (VUs, spawn rate, duration, methodology) as its newest run, so n can be lower than the number of runs queued.")
[void]$out.AppendLine("A small ±stddev across n>=3 runs is the green light to use those numbers as a regression baseline (see check-regression.ps1).")
[void]$out.AppendLine()

foreach ($samplerName in $samplers) {
    [void]$out.AppendLine("## Sampler: $samplerName")
    [void]$out.AppendLine()

    # Each cell follows its own newest run, so one smoke run queued last puts
    # that cell on a different load from its neighbours. When that happens,
    # say so and label every cell rather than let the rows read as comparable.
    $tableLoads = @(foreach ($version in $versions) {
        foreach ($tier in $tiers) {
            $cellKey = "${version}__${tier}__${samplerName}"
            if ($cells.ContainsKey($cellKey)) { Get-CellLoad $cells[$cellKey] }
        }
    }) | Where-Object { $_ } | Sort-Object -Unique
    $mixedLoads = @($tableLoads).Count -gt 1
    if ($mixedLoads) {
        [void]$out.AppendLine("> **Mixed loads in this table** - each cell shows its load and methodology version in brackets. Cells that differ in either are not comparable.")
        [void]$out.AppendLine()
    }

    $header = "| Version | " + ($tiers -join ' | ') + " |"
    $sep    = "|---|" + (($tiers | ForEach-Object { '---' }) -join '|') + "|"
    [void]$out.AppendLine($header)
    [void]$out.AppendLine($sep)

    foreach ($version in $versions) {
        $rowCells = foreach ($tier in $tiers) {
            $cellKey = "${version}__${tier}__${samplerName}"
            if (-not $cells.ContainsKey($cellKey)) { '-'; continue }
            Format-Cell $cells[$cellKey] $mixedLoads
        }
        [void]$out.AppendLine("| $version | " + ($rowCells -join ' | ') + " |")
    }
    [void]$out.AppendLine()
}

$report = $out.ToString()

if ($OutputPath) {
    $report | Out-File -FilePath $OutputPath -Encoding utf8
    Write-Host "Report written to: $OutputPath"
} else {
    Write-Host ""
    Write-Host $report
}
