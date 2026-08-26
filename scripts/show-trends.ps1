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

# Population stddev (divides by N): we're describing the spread of the K runs
# we have, not estimating a population from a sample. Bessel-corrected sample
# stddev would over-inflate the visible spread when N is small (3-5 runs).
function Get-PopulationStdDev([double[]] $values) {
    $n = $values.Count
    if ($n -le 1) { return 0 }
    $mean = ($values | Measure-Object -Average).Average
    $sumSq = 0.0
    foreach ($v in $values) { $sumSq += [math]::Pow($v - $mean, 2) }
    return [math]::Sqrt($sumSq / $n)
}

function Format-Cell($runs) {
    if (-not $runs -or $runs.Count -eq 0) { return '-' }

    # Median, not mean, to match the p95/p99 statistic in the same cell (and the
    # header's "median ±stddev" label). A mean let one bad run skew the error
    # figure in a way the latency figures beside it are explicitly protected
    # from, which made the cell internally inconsistent.
    $errPct = [math]::Round((Get-Median (@($runs | ForEach-Object { [double]$_.error_rate }))) * 100, 2)

    if ($runs.Count -eq 1) {
        $p95 = [int][math]::Round([double]$runs[0].p95_ms, 0)
        $p99 = [int][math]::Round([double]$runs[0].p99_ms, 0)
        return "$p95 / $p99 ($errPct%)"
    }

    $p95s = @($runs | ForEach-Object { [double]$_.p95_ms })
    $p99s = @($runs | ForEach-Object { [double]$_.p99_ms })

    $p95Med = [int][math]::Round((Get-Median $p95s), 0)
    $p99Med = [int][math]::Round((Get-Median $p99s), 0)
    $p95Std = [int][math]::Round((Get-PopulationStdDev $p95s), 0)
    $p99Std = [int][math]::Round((Get-PopulationStdDev $p99s), 0)

    return "$p95Med ±$p95Std / $p99Med ±$p99Std ($errPct%) n=$($runs.Count)"
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
[void]$out.AppendLine("A small ±stddev across n>=3 runs is the green light to use those numbers as a regression baseline (see check-regression.ps1).")
[void]$out.AppendLine()

foreach ($samplerName in $samplers) {
    [void]$out.AppendLine("## Sampler: $samplerName")
    [void]$out.AppendLine()

    $header = "| Version | " + ($tiers -join ' | ') + " |"
    $sep    = "|---|" + (($tiers | ForEach-Object { '---' }) -join '|') + "|"
    [void]$out.AppendLine($header)
    [void]$out.AppendLine($sep)

    foreach ($version in $versions) {
        $rowCells = foreach ($tier in $tiers) {
            $cellKey = "${version}__${tier}__${samplerName}"
            if (-not $cells.ContainsKey($cellKey)) { '-'; continue }
            Format-Cell $cells[$cellKey]
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
