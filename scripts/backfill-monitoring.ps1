#requires -Version 7.3

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
    Write-PipelineError "Couldn't resolve DCE '$DceName' in RG '$HistoryResourceGroup'. Run ensure-monitoring-infra.ps1 first."
}

$subId = az account show --query id -o tsv
$dcrPath = "/subscriptions/$subId/resourceGroups/$HistoryResourceGroup/providers/Microsoft.Insights/dataCollectionRules/${DcrName}?api-version=2022-06-01"
$dcrShow = az rest --method get --url "https://management.azure.com$dcrPath" -o json | ConvertFrom-Json
$dcrImmutableId = $dcrShow.properties.immutableId
if ([string]::IsNullOrWhiteSpace($dcrImmutableId)) {
    Write-PipelineError "Couldn't resolve DCR '$DcrName' immutableId. Run ensure-monitoring-infra.ps1 first."
}

# 2. Optionally collect existing run_ids so we can skip blobs we've already
#    ingested. The Logs Ingestion API doesn't dedupe — re-running without this
#    check creates duplicate rows.
# Keyed on (run_id, jmeter_test_name): a backoffice run publishes one blob per
# .jmx, all sharing a run_id, so run_id alone would skip five of six on a replay.
# Client rows have no jmeter_test_name, so the key degrades to run_id there.
$existingKeys = @{}
function Get-DedupKey($row) {
    $jmx = if ($row.PSObject.Properties.Name -contains 'jmeter_test_name') { [string]$row.jmeter_test_name } else { '' }
    return "$([string]$row.run_id)|$jmx"
}
$isClientTable = $TableName -eq "ClientMeasurement_CL"
if (-not $Force) {
    Write-Host "-> Querying existing run_ids in $TableName"
    $workspaceCustomerId = Get-LogAnalyticsWorkspaceCustomerId -WorkspaceName $WorkspaceName -ResourceGroupName $HistoryResourceGroup
    if ([string]::IsNullOrWhiteSpace($workspaceCustomerId)) {
        Write-PipelineError "Couldn't resolve workspace customerId. Run ensure-monitoring-infra.ps1 first or pass -Force to skip the dedup query."
    }
    # Referencing a column the table lacks is a KQL error, not an empty result.
    $dedupQuery = if ($isClientTable) {
        "$TableName | where isnotempty(run_id) | distinct run_id"
    } else {
        "$TableName | where isnotempty(run_id) | distinct run_id, jmeter_test_name"
    }
    try {
        $queryResult = Invoke-LogAnalyticsQuery -WorkspaceCustomerId $workspaceCustomerId -Query $dedupQuery
        foreach ($row in @($queryResult)) {
            if ($row.run_id) { $existingKeys[(Get-DedupKey $row)] = $true }
        }
        Write-Host "   $($existingKeys.Count) (run_id, jmeter_test_name) pair(s) already ingested"
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
$allBlobs = @(az storage blob list `
    --account-name $StorageAccountName `
    --account-key $storageKey `
    --container-name $ContainerName `
    --query "[?ends_with(name, 'summary.ndjson')].{name:name}" `
    -o json | ConvertFrom-Json)

# client/ blobs have a different schema (destined for ClientMeasurement_CL) -
# scope by prefix so they don't get posted into the wrong table.
$blobs = @($allBlobs | Where-Object { ($_.name -like "client/*") -eq $isClientTable })
Write-Host "   $($blobs.Count) blob(s) found (of $($allBlobs.Count) total summary.ndjson blobs in the container)"

if ($blobs.Count -eq 0) {
    Write-Host "Nothing to backfill."
    return
}

# 4. Token for the Logs Ingestion API. Lifetime is ~1h. A bulk historical
#    backfill (this script's main use) can run longer than that, so refresh on
#    a timer inside the loop — an expired token would otherwise surface only as
#    per-blob "ingestion failed" warnings that look like a data problem.
function Get-IngestionToken {
    az account get-access-token --resource https://monitor.azure.com --query accessToken -o tsv
}
$token = Get-IngestionToken
$tokenAcquiredAt = Get-Date

# 5. Per-blob: download, parse NDJSON, dedup by run_id, mirror the publish
#    script's TimeGenerated logic (one timestamp per run = the run start), POST.
$stats = @{ ingested = 0; skipped = 0; failed = 0; rows = 0 }
foreach ($blob in $blobs) {
    $blobName = $blob.name
    # Refresh well before the ~1h token lifetime so a long backfill never POSTs
    # with an expired token.
    if (((Get-Date) - $tokenAcquiredAt).TotalMinutes -ge 45) {
        $token = Get-IngestionToken
        $tokenAcquiredAt = Get-Date
    }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "loadtest-backfill-$([Guid]::NewGuid()).ndjson"
    try {
        az storage blob download `
            --account-name $StorageAccountName `
            --account-key $storageKey `
            --container-name $ContainerName `
            --name $blobName `
            --file $tmp `
            --no-progress | Out-Null

        # List[object] + .Add(): += on a PowerShell array is O(N²) and dominates
        # wall-clock on large multi-sampler/multi-engine history files.
        $rows = [System.Collections.Generic.List[object]]::new()
        foreach ($line in (Get-Content $tmp)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $rows.Add(($line | ConvertFrom-Json)) }
            catch { Write-Warning "   $blobName : skip malformed line" }
        }
        if ($rows.Count -eq 0) {
            Write-Host "-> $blobName  (empty, skipping)"
            $stats.skipped++
            continue
        }

        $runId = $rows[0].run_id
        if (-not $runId) {
            Write-Warning "-> $blobName  (no run_id on first row, skipping)"
            $stats.skipped++
            continue
        }
        $dedupKey = Get-DedupKey $rows[0]
        if (-not $Force -and $existingKeys.ContainsKey($dedupKey)) {
            Write-Host "-> $blobName  ($dedupKey already ingested, skipping)"
            $stats.skipped++
            continue
        }
        # Guard within this invocation too, against a duplicate publish.
        $existingKeys[$dedupKey] = $true

        # TimeGenerated = run_started_at, so one run's rows share a point on the
        # time axis. Client rows carry only TimeGenerated, hence the middle
        # fallback; without it every client backfill row got stamped with now().
        $ingestRows = $rows | ForEach-Object {
            $row = $_ | Select-Object *
            $ts  = $row.run_started_at
            if (-not $ts) { $ts = $row.TimeGenerated }
            if (-not $ts) {
                Write-Warning "   $blobName : row has neither run_started_at nor TimeGenerated, using current UTC"
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
Write-Host "  $TableName | summarize rows = count() by run_id, jmeter_test_name | order by rows desc"
Write-Host ""
Write-Host "First-time data takes 5-10 min to surface in a brand-new custom table; allow time before checking."
