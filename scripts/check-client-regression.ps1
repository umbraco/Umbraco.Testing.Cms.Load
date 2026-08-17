#requires -Version 7.3

# Client-measurement regression gate. Reads client summary.ndjson rows from
# history storage (the 'client/{major}/' prefix), takes the latest run per
# (version × tier × metric) cell as candidate, compares its median against the
# median-of-last-N baseline. Mirrors check-regression.ps1's philosophy: report-only
# until >= MinBaselineRuns accrue, then fails (unless -NoFailOnRegression) so it can
# gate the pipeline.

[CmdletBinding()]
param(
    [string]$Scenario,
    [int]$Major,
    [string]$HistoryResourceGroup,
    [string]$StorageAccountName,
    [string]$ContainerName,
    [string]$OutputPath,
    [double]$MedianThreshold = 0.10,
    [int]$MinBaselineRuns = 3,
    [int]$BaselineWindow = 5,
    [switch]$NoFailOnRegression,
    [switch]$DotSourceForTest
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

. "$PSScriptRoot/_helpers.ps1"
. "$PSScriptRoot/_history-helpers.ps1"

# Pure decision function — unit-tested. A metric regresses when it has enough
# baseline runs AND the candidate median exceeds baseline-median x (1+threshold).
function Test-ClientRegression {
    param(
        [Parameter(Mandatory)] [double]$CandidateMedian,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [double[]]$BaselineMedians,
        [double]$Threshold = 0.10,
        [int]$MinBaselineRuns = 3
    )
    if ($BaselineMedians.Count -lt $MinBaselineRuns) {
        return [pscustomobject]@{ Insufficient = $true; Regressed = $false; BaselineMedian = $null }
    }
    $baseMedian = Get-Median ([double[]]$BaselineMedians)
    $regressed = $CandidateMedian -gt ($baseMedian * (1 + $Threshold))
    return [pscustomobject]@{ Insufficient = $false; Regressed = $regressed; BaselineMedian = $baseMedian }
}

if ($DotSourceForTest) { return }

# Get-HistoryCells can't be reused: client rows use `metric` + the `client/`
# prefix (it filters scenario_name and the `{scenario}/` prefix).
$prefix = "client/$Major/"
$storageKey = Get-StorageAccountKey -StorageAccountName $StorageAccountName -ResourceGroupName $HistoryResourceGroup

Write-Host "Listing client summary blobs under $prefix..."
$listJson = az storage blob list `
    --account-name $StorageAccountName --account-key $storageKey `
    --container-name $ContainerName --prefix $prefix `
    --query "[?ends_with(name, 'summary.ndjson')].name" -o json
$blobNames = @($listJson | ConvertFrom-Json)

# Group rows by (version × tier × metric); each cell is a time-ordered list of rows.
$cells = @{}
foreach ($blob in $blobNames) {
    $tmp = New-TemporaryFile
    az storage blob download --account-name $StorageAccountName --account-key $storageKey `
        --container-name $ContainerName --name $blob --file $tmp.FullName --no-progress | Out-Null
    $lines = Get-Content -Path $tmp.FullName
    Remove-Item -LiteralPath $tmp.FullName -Force -ErrorAction SilentlyContinue
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $row = $line | ConvertFrom-Json } catch { continue }
        if (-not $row.metric) { continue }
        $cellKey = "$($row.umbraco_version)__$($row.infra_tier)__$($row.metric)"
        if (-not $cells.ContainsKey($cellKey)) { $cells[$cellKey] = [System.Collections.Generic.List[object]]::new() }
        $cells[$cellKey].Add($row)
    }
}

$report = New-Object System.Text.StringBuilder
[void]$report.AppendLine("# Client measurement regression report`n")
$regressedAny = $false
if ($cells.Count -eq 0) { [void]$report.AppendLine("No client runs found under $prefix.") }

foreach ($cellKey in ($cells.Keys | Sort-Object)) {
    # Order chronologically by parsed datetime, not string compare: rows written
    # before TimeGenerated was normalized to ISO-8601 use a different format and
    # would mis-sort lexically, picking the wrong candidate/baseline. Unparseable
    # timestamps sort first (treated as oldest) rather than throwing.
    $ordered = @($cells[$cellKey] | Sort-Object {
        try { [datetime]::Parse([string]$_.TimeGenerated, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal) }
        catch { [datetime]::MinValue }
    })
    if ($ordered.Count -lt 2) {
        [void]$report.AppendLine("- ${cellKey}: insufficient baseline (1 run)")
        continue
    }
    $candidate = $ordered[-1]
    $baselineRows = @($ordered[0..($ordered.Count - 2)] | Select-Object -Last $BaselineWindow)
    # Blank/unparseable median_ms -> $null (never 0). A 0 would read as "faster",
    # masking a regression on the candidate side and dragging the baseline median
    # down on the other. Candidate with no valid median can't be judged -> skip.
    $candMedian = ConvertTo-DoubleOrNull ([string]$candidate.median_ms)
    if ($null -eq $candMedian) {
        [void]$report.AppendLine("- ${cellKey}: skipped (candidate median missing/unparseable)")
        continue
    }
    $baselineMedians = [double[]]@($baselineRows | ForEach-Object { ConvertTo-DoubleOrNull ([string]$_.median_ms) } | Where-Object { $null -ne $_ })
    $verdict = Test-ClientRegression -CandidateMedian $candMedian `
        -BaselineMedians $baselineMedians -Threshold $MedianThreshold -MinBaselineRuns $MinBaselineRuns
    if ($verdict.Insufficient) {
        [void]$report.AppendLine("- ${cellKey}: insufficient baseline ($($baselineMedians.Count) < $MinBaselineRuns runs)")
    } elseif ($verdict.Regressed) {
        $regressedAny = $true
        [void]$report.AppendLine("- **${cellKey}: REGRESSED** candidate $([math]::Round($candMedian))ms > baseline-median $([math]::Round($verdict.BaselineMedian))ms x $(1 + $MedianThreshold)")
    } else {
        [void]$report.AppendLine("- ${cellKey}: ok ($([math]::Round($candMedian))ms vs $([math]::Round($verdict.BaselineMedian))ms)")
    }
}

$reportText = $report.ToString()
if ($OutputPath) { $reportText | Out-File -FilePath $OutputPath -Encoding utf8 }
Write-Host $reportText

if ($regressedAny -and -not $NoFailOnRegression) {
    Write-Host "##vso[task.logissue type=error]Client measurement regression detected."
    exit 1
}
exit 0
