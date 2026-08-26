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
    [switch]$DotSourceForTest,

    # Optional LA target for ClientMeasurement_CL, mirroring check-regression.ps1.
    # Empty (default) skips posting.
    [string]$LogAnalyticsDceUri,
    [string]$LogAnalyticsDcrImmutableId,
    [string]$LogAnalyticsClientStreamName
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

# $Major has no [Parameter(Mandatory)] (matches this script's other "real" run
# params, left optional so -DotSourceForTest doesn't need to supply them) - but
# an omitted/zero value must fail loudly here, not silently build a
# 'client/0/' blob prefix that matches nothing and reports a false "no client
# runs found" pass.
if ($Major -le 0) {
    Write-Host "##vso[task.logissue type=error]check-client-regression: -Major must be a positive Umbraco major version, got '$Major'."
    exit 1
}

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

# Per-cell verdict + candidate row, keyed by cellKey — used below to build the
# Log Analytics rows (one per run, aggregated across that run's metric cells).
$cellVerdicts = @{}

foreach ($cellKey in ($cells.Keys | Sort-Object)) {
    # Order chronologically by parsed datetime, not string compare: rows written
    # before TimeGenerated was normalized to ISO-8601 use a different format and
    # would mis-sort lexically, picking the wrong candidate/baseline. Unparseable
    # timestamps sort first (treated as oldest) rather than throwing.
    $ordered = @($cells[$cellKey] | Sort-Object {
        try { [datetime]::Parse([string]$_.TimeGenerated, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal) }
        catch { [datetime]::MinValue }
    })
    $candidate = $ordered[-1]
    if ($ordered.Count -lt 2) {
        [void]$report.AppendLine("- ${cellKey}: insufficient baseline (1 run)")
        $cellVerdicts[$cellKey] = [pscustomobject]@{ Candidate = $candidate; Regressed = $false; Insufficient = $true }
        continue
    }
    $baselineRows = @($ordered[0..($ordered.Count - 2)] | Select-Object -Last $BaselineWindow)
    # Blank/unparseable median_ms -> $null (never 0). A 0 would read as "faster",
    # masking a regression on the candidate side and dragging the baseline median
    # down on the other. Candidate with no valid median can't be judged -> skip.
    $candMedian = ConvertTo-DoubleOrNull ([string]$candidate.median_ms)
    if ($null -eq $candMedian) {
        [void]$report.AppendLine("- ${cellKey}: skipped (candidate median missing/unparseable)")
        $cellVerdicts[$cellKey] = [pscustomobject]@{ Candidate = $candidate; Regressed = $false; Insufficient = $true }
        continue
    }
    $baselineMedians = [double[]]@($baselineRows | ForEach-Object { ConvertTo-DoubleOrNull ([string]$_.median_ms) } | Where-Object { $null -ne $_ })
    $verdict = Test-ClientRegression -CandidateMedian $candMedian `
        -BaselineMedians $baselineMedians -Threshold $MedianThreshold -MinBaselineRuns $MinBaselineRuns
    $cellVerdicts[$cellKey] = [pscustomobject]@{ Candidate = $candidate; Regressed = $verdict.Regressed; Insufficient = $verdict.Insufficient }
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

# Post regression-check status to ClientMeasurement_CL, mirroring
# check-regression.ps1. Failure here warns and continues - the build
# artifact remains authoritative.
if ($LogAnalyticsDceUri -and $LogAnalyticsDcrImmutableId -and $LogAnalyticsClientStreamName) {
    $statusByGroup = @{}   # key: run_id|scenario|version|tier
    foreach ($cellKey in $cellVerdicts.Keys) {
        $v         = $cellVerdicts[$cellKey]
        $candidate = $v.Candidate
        $parts     = $cellKey -split '__', 3
        $version   = $parts[0]
        $tier      = $parts[1]
        $metric    = $parts[2]

        $groupKey = "$($candidate.run_id)|$($candidate.scenario)|$version|$tier"
        if (-not $statusByGroup.ContainsKey($groupKey)) {
            $statusByGroup[$groupKey] = [pscustomobject]@{
                run_id             = $candidate.run_id
                scenario           = $candidate.scenario
                umbraco_version    = $version
                infra_tier         = $tier
                commit             = $candidate.commit
                branch             = $candidate.branch
                app_service_sku    = $candidate.app_service_sku
                pool_dtu_max       = $candidate.pool_dtu_max
                seeder_preset      = $candidate.seeder_preset
                regressed_metrics  = New-Object System.Collections.Generic.List[string]
                insufficient_count = 0
                checked_count      = 0
            }
        }
        $g = $statusByGroup[$groupKey]
        $g.checked_count++
        if ($v.Regressed)     { $g.regressed_metrics.Add($metric) }
        if ($v.Insufficient)  { $g.insufficient_count++ }
    }

    if ($statusByGroup.Count -gt 0) {
        $now = (Get-Date).ToUniversalTime().ToString("o")
        $rows = foreach ($g in $statusByGroup.Values) {
            $regressedList = ($g.regressed_metrics -join ',')
            $verdict =
                if ($g.regressed_metrics.Count -gt 0) { 'regress' }
                elseif ($g.insufficient_count -eq $g.checked_count) { 'insufficient' }
                else { 'pass' }
            [pscustomobject]@{
                TimeGenerated     = $now
                run_id            = [string]$g.run_id
                scenario          = [string]$g.scenario
                umbraco_version   = [string]$g.umbraco_version
                infra_tier        = [string]$g.infra_tier
                commit            = [string]$g.commit
                branch            = [string]$g.branch
                app_service_sku   = [string]$g.app_service_sku
                pool_dtu_max      = $g.pool_dtu_max
                seeder_preset     = [string]$g.seeder_preset
                metric            = 'regression_check'
                regression_status = $verdict
                regressed_metrics = $regressedList
                regressed_count   = $g.regressed_metrics.Count
            }
        }

        Write-Host ""
        Write-Host "Posting $($rows.Count) regression-status row(s) to Log Analytics ($LogAnalyticsClientStreamName)"
        try {
            $token = az account get-access-token --resource https://monitor.azure.com --query accessToken -o tsv
            $body  = ConvertTo-Json -InputObject @($rows) -Depth 5 -Compress -AsArray
            $url   = "$LogAnalyticsDceUri/dataCollectionRules/$LogAnalyticsDcrImmutableId/streams/${LogAnalyticsClientStreamName}?api-version=2023-01-01"
            Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType "application/json" `
                -Headers @{ Authorization = "Bearer $token" } | Out-Null
            Write-Host "   ok"
        }
        catch {
            $msg = "Client regression-status ingestion failed: $($_.Exception.Message). Build artifact ($OutputPath) remains authoritative."
            Write-Warning $msg
            Write-Host "##vso[task.logissue type=warning]$msg"
        }
    }
}

if ($regressedAny -and -not $NoFailOnRegression) {
    Write-Host "##vso[task.logissue type=error]Client measurement regression detected."
    exit 1
}
exit 0
