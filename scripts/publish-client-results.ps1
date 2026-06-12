#requires -Version 7.3

# Publish client-measurement results to history storage + Log Analytics:
#   client/{major}/{umbracoVersion}/{tier}/{yyyy-MM-dd}_{buildId}/summary.ndjson
#   client/{major}/{umbracoVersion}/{tier}/{yyyy-MM-dd}_{buildId}/raw/...   (per-metric NDJSON)
#
# Mirrors publish-load-test-results.ps1 but for the Playwright `client` workload.
# Client perceived-latency rows go to their own table (ClientMeasurement_CL).

[CmdletBinding()]
param(
    [string]$ResultsDir,
    [string]$HistoryResourceGroup,
    [string]$StorageAccountName,
    [string]$ContainerName,
    [string]$BuildId,
    [string]$Commit,
    [string]$Branch,
    [string]$RunStartedAt,
    [string]$UmbracoVersion,
    [string]$AppServiceSku,
    [int]$PoolDtuMax,
    [string]$SeederPreset,
    [string]$Tier,
    [string]$Scenario,
    [string]$LogAnalyticsDceUri,
    [string]$LogAnalyticsDcrImmutableId,
    [string]$LogAnalyticsClientStreamName,
    # Lets the Pester test dot-source the file to test Build-ClientRows without running main.
    [switch]$DotSourceForTest
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

. "$PSScriptRoot/_helpers.ps1"

# Transform the Playwright per-metric NDJSON files into LA-shaped rows carrying
# full run metadata, so cross-run queries need no joins. Pure function — unit-tested.
function Build-ClientRows {
    param(
        [Parameter(Mandatory)] [string]$ResultsDir,
        [Parameter(Mandatory)] [string]$UmbracoVersion,
        [Parameter(Mandatory)] [string]$Tier,
        [Parameter(Mandatory)] [string]$Scenario,
        [Parameter(Mandatory)] [string]$AppServiceSku,
        [Parameter(Mandatory)] [int]$PoolDtuMax,
        [Parameter(Mandatory)] [string]$SeederPreset,
        [Parameter(Mandatory)] [string]$BuildId,
        [Parameter(Mandatory)] [string]$Commit,
        [Parameter(Mandatory)] [string]$Branch,
        [Parameter(Mandatory)] [string]$RunStartedAt
    )
    # List[object] for O(1) appends; += on PowerShell arrays is O(N^2).
    $rows = [System.Collections.Generic.List[object]]::new()
    $files = @(Get-ChildItem -Path $ResultsDir -Filter '*.ndjson' -File -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
        foreach ($line in (Get-Content $f.FullName)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $m = $line | ConvertFrom-Json
            $rows.Add([pscustomobject][ordered]@{
                TimeGenerated       = $RunStartedAt
                run_id              = $BuildId
                commit              = $Commit
                branch              = $Branch
                umbraco_version     = $UmbracoVersion
                app_service_sku     = $AppServiceSku
                pool_dtu_max        = $PoolDtuMax
                seeder_preset       = $SeederPreset
                infra_tier          = $Tier
                scenario            = $Scenario
                metric              = $m.metric
                count               = $m.count
                median_ms           = $m.median
                p75_ms              = $m.p75
                p95_ms              = $m.p95
                min_ms              = $m.min
                max_ms              = $m.max
                stddev_ms           = $m.stddev
                ttfb_ms             = $m.ttfb_ms
                dcl_ms              = $m.dcl_ms
                load_ms             = $m.load_ms
                lcp_ms              = $m.lcp_ms
                seg_login_ms        = $m.seg_login_median
                seg_navigate_ms     = $m.seg_navigate_median
                seg_editor_ready_ms = $m.seg_editor_ready_median
                seg_keystroke_ms    = $m.seg_keystroke_median
            })
        }
    }
    # Unary comma forces an array return even for a single row — otherwise a
    # 1-element array unrolls to a scalar and callers' $rows.Count would resolve
    # to the row's own `count` property instead of the array length.
    return ,$rows
}

# Logs Ingestion mirror — same shape as publish-load-test-results.ps1's sender.
function Send-ClientRowsToLogAnalytics {
    param([Parameter(Mandatory)] [object[]]$Rows)
    if (-not ($LogAnalyticsDceUri -and $LogAnalyticsDcrImmutableId -and $LogAnalyticsClientStreamName)) { return }
    Write-Host "Posting $($Rows.Count) client row(s) to Log Analytics ($LogAnalyticsClientStreamName)"
    try {
        $token = az account get-access-token --resource https://monitor.azure.com --query accessToken -o tsv
        $body  = ConvertTo-Json -InputObject @($Rows) -Depth 5 -Compress -AsArray
        $url   = "$LogAnalyticsDceUri/dataCollectionRules/$LogAnalyticsDcrImmutableId/streams/${LogAnalyticsClientStreamName}?api-version=2023-01-01"
        Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType "application/json" `
            -Headers @{ Authorization = "Bearer $token" } | Out-Null
        Write-Host "   ok"
    } catch {
        $msg = "Client Log Analytics ingestion failed: $($_.Exception.Message). Blob upload remains source of truth."
        Write-Warning $msg
        Write-Host "##vso[task.logissue type=warning]$msg"
    }
}

if ($DotSourceForTest) { return }

if (-not (Test-Path $ResultsDir)) {
    Write-Warning "Results dir '$ResultsDir' not found - nothing to publish."
    exit 0
}

$rows = Build-ClientRows -ResultsDir $ResultsDir -UmbracoVersion $UmbracoVersion -Tier $Tier `
    -Scenario $Scenario -AppServiceSku $AppServiceSku -PoolDtuMax $PoolDtuMax -SeederPreset $SeederPreset `
    -BuildId $BuildId -Commit $Commit -Branch $Branch -RunStartedAt $RunStartedAt
if ($rows.Count -eq 0) { Write-Warning "No client metric rows parsed from $ResultsDir." }

# Blob path mirrors publish-load-test-results.ps1 with a 'client/' top-level prefix.
$pipelineStarted = [DateTime]::Parse($RunStartedAt, [System.Globalization.CultureInfo]::InvariantCulture)
$datePart        = $pipelineStarted.ToString("yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)
$majorVersion    = (Get-UmbracoMajor $UmbracoVersion).ToString()
$blobPrefix      = "client/$majorVersion/$UmbracoVersion/$Tier/${datePart}_$BuildId"

$summaryFile = Join-Path (Split-Path -Parent $ResultsDir) "client-summary.ndjson"
$rows | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 } | Out-File -FilePath $summaryFile -Encoding utf8

$storageKey = Get-StorageAccountKey -StorageAccountName $StorageAccountName -ResourceGroupName $HistoryResourceGroup
Write-Host "Uploading to https://$StorageAccountName.blob.core.windows.net/$ContainerName/$blobPrefix/"
az storage blob upload --account-name $StorageAccountName --account-key $storageKey `
    --container-name $ContainerName --file $summaryFile --name "$blobPrefix/summary.ndjson" --overwrite | Out-Null
az storage blob upload-batch --account-name $StorageAccountName --account-key $storageKey `
    --destination $ContainerName --destination-path "$blobPrefix/raw" --source $ResultsDir --pattern "*.ndjson" --overwrite | Out-Null

Send-ClientRowsToLogAnalytics -Rows $rows
Write-Host "Published $($rows.Count) client metric row(s)."
