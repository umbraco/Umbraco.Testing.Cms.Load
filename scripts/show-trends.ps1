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
    [string]$OutputPath,

    # Optional scope: only the newest -Window like-for-like runs per cell (0 =
    # all of them), and/or only these build ids / runs started since this time.
    [ValidateRange(0, 100)] [int]$Window = 0,
    [string[]]$RunIds,
    [Nullable[datetime]]$Since,

    # Same meaning as on compare-runs.ps1: -ExcludeRunIds drops runs you know
    # were invalid; -MaxErrorRate (percent, off when negative) leaves runs over
    # that error rate out of the latency medians only, and each cell says how
    # many ("K over limit"; "!" when every run was over it).
    [string[]]$ExcludeRunIds,
    [double]$MaxErrorRate = -1
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
    $runs = @(Select-LikeForLikeRuns -Runs @($allRuns) -First $Window)
    $load = if ($ShowLoad) { " [$(Get-CellLoad $allRuns)]" } else { '' }

    # Median, not mean, to match the p95/p99 statistic in the same cell - a mean
    # let one bad run skew the figure the latencies beside it are protected from.
    $errPct = [math]::Round((Get-Median (@($runs | ForEach-Object { [double]$_.error_rate }))) * 100, 2)
    # A median hides failures in fewer than half the runs, so the worst single
    # run rides along whenever it is higher.
    $errMax = [math]::Round((@($runs | ForEach-Object { [double]$_.error_rate }) | Measure-Object -Maximum).Maximum * 100, 2)
    $errText = if ($errMax -gt $errPct) { "$errPct%, worst $errMax%" } else { "$errPct%" }

    # Latency from the runs under the error limit only; err% above counts all.
    $split   = Split-ByErrorLimit -Runs $runs -MaxErrorRate $MaxErrorRate
    $latency = @($split.Latency)
    $limit   = if ($split.AllOver) { ' !' } elseif ($split.Over.Count -gt 0) { " $($split.Over.Count) over limit" } else { '' }

    if ($runs.Count -eq 1) {
        $p95 = [int][math]::Round([double]$runs[0].p95_ms, 0)
        $p99 = [int][math]::Round([double]$runs[0].p99_ms, 0)
        return "$p95 / $p99 ($errText)$limit$load"
    }

    $p95s = @($latency | ForEach-Object { [double]$_.p95_ms })
    $p99s = @($latency | ForEach-Object { [double]$_.p99_ms })

    $p95Med = [int][math]::Round((Get-Median $p95s), 0)
    $p99Med = [int][math]::Round((Get-Median $p99s), 0)
    $p95Std = [int][math]::Round((Get-PopulationStdDev $p95s), 0)
    $p99Std = [int][math]::Round((Get-PopulationStdDev $p99s), 0)

    return "$p95Med ±$p95Std / $p99Med ±$p99Std ($errText) n=$($runs.Count)$limit$load"
}

# --- Load history ---

$cells = Get-HistoryCells `
    -Scenario $Scenario `
    -HistoryResourceGroup $HistoryResourceGroup `
    -StorageAccountName $StorageAccountName `
    -ContainerName $ContainerName `
    -Major $Major `
    -Sampler $Sampler `
    -OnlyRunIds $RunIds -Since $Since -ExcludeRunIds $ExcludeRunIds

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
# Say what was scoped or left out, so a matrix can't be read as "all history".
$scope = @()
if ($Window -gt 0)    { $scope += "newest $Window like-for-like run(s) per cell" }
if ($RunIds)          { $scope += "only runs $((@($RunIds | ForEach-Object { "$_" -split ',' } | ForEach-Object { "#$($_.Trim().TrimStart('#'))" })) -join ', ')" }
if ($Since)           { $scope += "runs started on or after $((ConvertTo-SinceUtc ([datetime]$Since)).ToString('dd-MM-yyyy HH:mm', [cultureinfo]::InvariantCulture)) UTC" }
if ($ExcludeRunIds)   { $scope += "excluded by you: $((@($ExcludeRunIds | ForEach-Object { "$_" -split ',' } | ForEach-Object { "#$($_.Trim().TrimStart('#'))" })) -join ', ')" }
if ($MaxErrorRate -ge 0) { $scope += "runs over $MaxErrorRate% errors left out of the latency medians only ('K over limit' in the cell; '!' = every run was over it, so the latency shown is that of failing runs)" }
if ($scope.Count -gt 0) { [void]$out.AppendLine("Scope: $($scope -join '; ').") }
[void]$out.AppendLine("Each cell counts only the runs that drove the same load (VUs, spawn rate, duration, methodology) on the same setup (SKU, DTU cap, seeder preset and build) as its newest run, so n can be lower than the number of runs queued. 'worst' is the highest error rate of any single run, shown when it is above the median.")
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
