# Backfill summary rows from blob storage to the Log Analytics custom table.
# Useful when:
#   - Migrating from a blob-only setup to the Workbook (one-shot fill of
#     historical runs that pre-date the monitoring infra).
#   - Replaying a run whose original publish step succeeded at the blob upload
#     but failed at the Logs Ingestion API step (warning surfaces in the job
#     log; this is the recovery path).
#
# Idempotency: by default, queries existing run_ids in the table and skips any
# blob whose run is already there. Pass -Force to re-ingest everything (the
# Logs Ingestion API does NOT dedupe — re-running with -Force creates duplicate
# rows).
#
# Prereqs:
#   - az CLI logged in
#   - The principal running this script needs:
#       - Storage Account Contributor (or any role with listKeys/action) on
#         the history storage account — to read the NDJSON blobs.
#       - Monitoring Metrics Publisher on the DCR — to POST rows. Granted to
#         the pipeline SP by ensure-monitoring-infra.ps1; for a local-dev user
#         a manual portal grant on the DCR scope is the same idea.
#       - Log Analytics Reader on the workspace — for the dedup query. Skip
#         this requirement with -Force.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$HistoryResourceGroup,
    [Parameter(Mandatory = $true)] [string]$StorageAccountName,
    [Parameter(Mandatory = $true)] [string]$ContainerName,
    [Parameter(Mandatory = $true)] [string]$WorkspaceName,
    [Parameter(Mandatory = $true)] [string]$DceName,
    [Parameter(Mandatory = $true)] [string]$DcrName,
    [string]$TableName  = "LoadTestSummary_CL",
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

. "$PSScriptRoot/_helpers.ps1"

$streamName = "Custom-$TableName"

Write-Host "=== Backfill summary rows: blob storage -> Log Analytics ==="
Write-Host "  Storage:    $StorageAccountName / $ContainerName"
Write-Host "  Workspace:  $WorkspaceName"
Write-Host "  DCE / DCR:  $DceName / $DcrName"
Write-Host "  Table:      $TableName"
Write-Host "  Force:      $Force"
Write-Host ""

# 1. Resolve the DCE URI and DCR immutable ID. Same lookups ensure-monitoring-
#    infra.ps1 prints at the end of its run; we resolve them fresh so this
#    script stands alone.
$dceShow = az monitor data-collection endpoint show -n $DceName -g $HistoryResourceGroup -o json | ConvertFrom-Json
$dceUri  = $dceShow.logsIngestion.endpoint
if ([string]::IsNullOrWhiteSpace($dceUri)) {
    Write-Error "Couldn't resolve DCE '$DceName' in RG '$HistoryResourceGroup'. Run ensure-monitoring-infra.ps1 first."
    exit 1
}

$subId = az account show --query id -o tsv
$dcrPath = "/subscriptions/$subId/resourceGroups/$HistoryResourceGroup/providers/Microsoft.Insights/dataCollectionRules/${DcrName}?api-version=2022-06-01"
$dcrShow = az rest --method get --url "https://management.azure.com$dcrPath" -o json | ConvertFrom-Json
$dcrImmutableId = $dcrShow.properties.immutableId
if ([string]::IsNullOrWhiteSpace($dcrImmutableId)) {
    Write-Error "Couldn't resolve DCR '$DcrName' immutableId. Run ensure-monitoring-infra.ps1 first."
    exit 1
}

# 2. Optionally collect existing run_ids so we can skip blobs we've already
#    ingested. The Logs Ingestion API doesn't dedupe — re-running without this
#    check creates duplicate rows.
$existingRunIds = @{}
if (-not $Force) {
    Write-Host "-> Querying existing run_ids in $TableName"
    $workspaceCustomerId = az monitor log-analytics workspace show -n $WorkspaceName -g $HistoryResourceGroup --query customerId -o tsv
    if ([string]::IsNullOrWhiteSpace($workspaceCustomerId)) {
        Write-Error "Couldn't resolve workspace customerId. Run ensure-monitoring-infra.ps1 first or pass -Force to skip the dedup query."
        exit 1
    }
    try {
        $queryResult = az monitor log-analytics query `
            -w $workspaceCustomerId `
            --analytics-query "$TableName | where isnotempty(run_id) | distinct run_id" `
            -o json | ConvertFrom-Json
        foreach ($row in @($queryResult)) {
            if ($row.run_id) { $existingRunIds[$row.run_id] = $true }
        }
        Write-Host "   $($existingRunIds.Count) run_id(s) already ingested"
    }
    catch {
        Write-Warning "Couldn't query existing run_ids: $($_.Exception.Message). Pass -Force to skip this check (re-ingests everything; creates duplicates if anything is already there)."
        exit 1
    }
}

# 3. Storage key for the blob list/download. Same auth path as
#    publish-load-test-results.ps1 — keeps RBAC requirements narrow.
$storageKey = Get-StorageAccountKey -StorageAccountName $StorageAccountName -ResourceGroupName $HistoryResourceGroup

Write-Host "-> Listing summary.ndjson blobs"
$blobs = @(az storage blob list `
    --account-name $StorageAccountName `
    --account-key $storageKey `
    --container-name $ContainerName `
    --query "[?ends_with(name, 'summary.ndjson')].{name:name}" `
    -o json | ConvertFrom-Json)
Write-Host "   $($blobs.Count) blob(s) found"

if ($blobs.Count -eq 0) {
    Write-Host "Nothing to backfill."
    return
}

# 4. Token for the Logs Ingestion API. Lifetime is ~1h — fine for any realistic
#    run count. If you somehow have thousands of blobs, refresh in the loop.
$token = az account get-access-token --resource https://monitor.azure.com --query accessToken -o tsv

# 5. Per-blob: download, parse NDJSON, dedup by run_id, mirror the publish
#    script's TimeGenerated logic (one timestamp per run = the run start), POST.
$stats = @{ ingested = 0; skipped = 0; failed = 0; rows = 0 }
foreach ($blob in $blobs) {
    $blobName = $blob.name
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "loadtest-backfill-$([Guid]::NewGuid()).ndjson"
    try {
        az storage blob download `
            --account-name $StorageAccountName `
            --account-key $storageKey `
            --container-name $ContainerName `
            --name $blobName `
            --file $tmp `
            --no-progress | Out-Null

        $rows = @()
        foreach ($line in (Get-Content $tmp)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $rows += ($line | ConvertFrom-Json) }
            catch { Write-Warning "   $blobName : skip malformed line" }
        }
        if ($rows.Count -eq 0) {
            Write-Host "-> $blobName  (empty, skipping)"
            continue
        }

        $runId = $rows[0].run_id
        if (-not $runId) {
            Write-Warning "-> $blobName  (no run_id on first row, skipping)"
            $stats.skipped++
            continue
        }
        if (-not $Force -and $existingRunIds.ContainsKey($runId)) {
            Write-Host "-> $blobName  (run_id=$runId already ingested, skipping)"
            $stats.skipped++
            continue
        }

        # Mirror publish-load-test-results.ps1: TimeGenerated = run_started_at,
        # so all per-sampler rows of one run share a single point on the time
        # axis. If run_started_at is missing on some old row, fall back to UTC
        # now and warn — better than dropping the row.
        $ingestRows = $rows | ForEach-Object {
            $row = $_ | Select-Object *
            $ts  = $row.run_started_at
            if (-not $ts) {
                Write-Warning "   $blobName : row missing run_started_at, using current UTC"
                $ts = (Get-Date).ToUniversalTime().ToString("o")
            }
            $row | Add-Member -NotePropertyName TimeGenerated -NotePropertyValue $ts -Force
            $row
        }

        $body = ConvertTo-Json -InputObject @($ingestRows) -Depth 5 -Compress -AsArray
        $url  = "$dceUri/dataCollectionRules/$dcrImmutableId/streams/${streamName}?api-version=2023-01-01"
        try {
            Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType "application/json" `
                -Headers @{ Authorization = "Bearer $token" } | Out-Null
            $stats.ingested++
            $stats.rows += $ingestRows.Count
            Write-Host "-> $blobName  (ingested $($ingestRows.Count) row(s), run_id=$runId)"
        }
        catch {
            Write-Warning "-> $blobName  (ingestion failed: $($_.Exception.Message))"
            $stats.failed++
        }
    }
    finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "=== Backfill complete ==="
Write-Host "  Ingested: $($stats.ingested) blob(s) / $($stats.rows) row(s)"
Write-Host "  Skipped:  $($stats.skipped)"
Write-Host "  Failed:   $($stats.failed)"
Write-Host ""
Write-Host "Verify in Log Analytics:"
Write-Host "  $TableName | summarize rows = count() by run_id | order by rows desc"
Write-Host ""
Write-Host "First-time data takes 5-10 min to surface in a brand-new custom table; allow time before checking."
