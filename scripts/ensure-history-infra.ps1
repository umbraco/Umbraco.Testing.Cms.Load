#requires -Version 7.3

# Idempotently ensure the long-lived "history" infra exists: RG, Azure Load Testing, storage, container.
# First run creates; subsequent runs no-op. Account-key auth avoids RBAC propagation delays.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$HistoryResourceGroup,
    [Parameter(Mandatory = $true)] [string]$HistoryLocation,
    [Parameter(Mandatory = $true)] [string]$LoadTestName,
    [Parameter(Mandatory = $true)] [string]$StorageAccountName,
    [Parameter(Mandatory = $true)] [string]$ContainerName,
    # Lifecycle policy thresholds (days). Set either to 0 to disable that
    # transition.
    #
    # Default is Cool@30d, Archive disabled. Reason: the policy filter is
    # coarse — it applies to ALL blobs in the container, including the
    # summary.ndjson files the PS analysis tools (show-trends.ps1,
    # compare-runs.ps1, check-regression.ps1, backfill-monitoring.ps1) read.
    # Cool tier is instant retrieval at slightly higher per-read cost — fine.
    # Archive tier takes HOURS to rehydrate, so older summary.ndjson reads
    # would fail with HTTP 409 until manually rehydrated. Cool-only sidesteps
    # that. Override -LifecycleArchiveAfterDays only if you've segregated
    # raw zips to a different prefix (and updated the policy filter to match)
    # or you're OK with the rehydration delay on year-old data.
    [int]$LifecycleCoolAfterDays    = 30,
    [int]$LifecycleArchiveAfterDays = 0
)

$ErrorActionPreference = "Stop"

# Make native commands (az CLI) honour $ErrorActionPreference so a failed `az group create`
# fails fast instead of cascading errors through subsequent steps. Requires pwsh 7.3+.
$PSNativeCommandUseErrorActionPreference = $true

. "$PSScriptRoot/_helpers.ps1"

# Catch the placeholder default explicitly; the global check below could miss it if it's available.
if ($StorageAccountName -eq 'loadtestchangeme') {
    Write-PipelineError "historyStorageAccount is still set to the placeholder 'loadtestchangeme'. Override it with a globally-unique 3-24 lowercase alphanumeric value, then re-run."
}

# `az load` extension isn't pre-installed on every agent image.
az extension add --name load --upgrade --only-show-errors | Out-Null

# Tags applied to every long-lived resource. managed_by distinguishes long-lived from ephemeral RGs.
$tags = @("project=umbraco-loadtest", "managed_by=ensure-script")

Write-Host "=== Ensuring history infrastructure ==="
Write-Host "  RG:         $HistoryResourceGroup"
Write-Host "  Location:   $HistoryLocation"
Write-Host "  Load test:  $LoadTestName"
Write-Host "  Storage:    $StorageAccountName"
Write-Host "  Container:  $ContainerName"
Write-Host ""

# Resource group
Write-Host "-> Resource group"
if ((az group exists -n $HistoryResourceGroup) -eq 'true') {
    Write-Host "   already exists"
}
else {
    az group create -n $HistoryResourceGroup -l $HistoryLocation --tags $tags | Out-Null
    Write-Host "   created"
}

# `az X show` exits non-zero when the resource doesn't exist; with
# $PSNativeCommandUseErrorActionPreference on, that would throw. Wrap each
# existence check in try/catch so a "not found" falls through to the create branch.
function Test-AzResource([scriptblock] $Probe) {
    try {
        $result = & $Probe 2>$null
        return [bool]$result
    } catch {
        return $false
    }
}

# Azure Load Testing resource
Write-Host "-> Load test resource"
if (Test-AzResource { az load show -n $LoadTestName -g $HistoryResourceGroup }) {
    Write-Host "   already exists"
}
else {
    az load create -n $LoadTestName -g $HistoryResourceGroup -l $HistoryLocation --tags $tags | Out-Null
    Write-Host "   created"
}

# Storage account: check our RG first; only do the global name-availability check when needed.
Write-Host "-> Storage account"
if (Test-AzResource { az storage account show -n $StorageAccountName -g $HistoryResourceGroup }) {
    Write-Host "   already exists"
}
else {
    $availability = az storage account check-name --name $StorageAccountName | ConvertFrom-Json
    if (-not $availability.nameAvailable) {
        Write-PipelineError "Storage account '$StorageAccountName' not available globally ($($availability.reason): $($availability.message)). Override historyStorageAccount with a globally unique value."
    }
    az storage account create `
        -n $StorageAccountName `
        -g $HistoryResourceGroup `
        -l $HistoryLocation `
        --sku Standard_LRS `
        --kind StorageV2 `
        --min-tls-version TLS1_2 `
        --allow-blob-public-access false `
        --tags $tags | Out-Null
    Write-Host "   created"
}

# Container
Write-Host "-> Container"
$storageKey = Get-StorageAccountKey -StorageAccountName $StorageAccountName -ResourceGroupName $HistoryResourceGroup
$containerExists = az storage container exists `
    --name $ContainerName `
    --account-name $StorageAccountName `
    --account-key $storageKey `
    --query exists -o tsv
if ($containerExists -eq 'true') {
    Write-Host "   already exists"
}
else {
    az storage container create `
        -n $ContainerName `
        --account-name $StorageAccountName `
        --account-key $storageKey `
        --public-access off | Out-Null
    Write-Host "   created"
}

# Blob lifecycle: tier aged results to Cool/Archive so this long-lived account
# doesn't grow unbounded on hot tier. Idempotent (create replaces any existing
# policy). Set either threshold to 0 to disable that transition.
Write-Host "-> Lifecycle policy"
$baseBlob = @{}
if ($LifecycleCoolAfterDays -gt 0)    { $baseBlob.tierToCool    = @{ daysAfterModificationGreaterThan = $LifecycleCoolAfterDays } }
if ($LifecycleArchiveAfterDays -gt 0) { $baseBlob.tierToArchive = @{ daysAfterModificationGreaterThan = $LifecycleArchiveAfterDays } }
if ($baseBlob.Count -eq 0) {
    Write-Host "   skipped (both thresholds disabled)"
}
else {
    $policy = @{ rules = @(@{
        enabled    = $true
        name       = "tier-loadtest-results"
        type       = "Lifecycle"
        definition = @{ filters = @{ blobTypes = @("blockBlob") }; actions = @{ baseBlob = $baseBlob } }
    }) }
    $policyFile = Join-Path ([IO.Path]::GetTempPath()) "loadtest-lifecycle-$([Guid]::NewGuid()).json"
    ($policy | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $policyFile -Encoding utf8
    try {
        az storage account management-policy create `
            --account-name $StorageAccountName `
            --resource-group $HistoryResourceGroup `
            --policy "@$policyFile" | Out-Null
        Write-Host "   applied (Cool@${LifecycleCoolAfterDays}d, Archive@${LifecycleArchiveAfterDays}d; 0=disabled)"
    }
    catch {
        # The lifecycle policy is a cost optimisation, not correctness. A failed
        # write (Azure Policy deny, RBAC gap on managementPolicies/write, throttle)
        # must NOT fail this stage — it gates provision/loadTest for the whole run.
        # Warn and continue; results still upload, they just won't auto-tier yet.
        Write-Host "##vso[task.logissue type=warning]Could not apply blob lifecycle policy ($($_.Exception.Message)); continuing. Hot-tier data won't auto-tier until this is resolved."
    }
    finally {
        Remove-Item -LiteralPath $policyFile -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "History infrastructure ready."
