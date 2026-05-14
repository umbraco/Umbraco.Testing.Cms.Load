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
    Write-Error @"
historyStorageAccount is still set to the placeholder 'loadtestchangeme'.
Override the variable with a globally-unique 3-24 lowercase alphanumeric value, then re-run.
"@
    exit 1
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
        Write-Error "Storage account '$StorageAccountName' not available globally ($($availability.reason): $($availability.message)). Override historyStorageAccount with a globally unique value."
        exit 1
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

# Storage lifecycle policy. Tiers older blobs to Cool / Archive automatically
# so storage cost stays sub-linear with run history. Idempotent — the create
# command replaces the existing policy in place; re-running with the same
# settings is a no-op effectively. Applies to ALL blobs in the container,
# including summary.ndjson — those are tiny so the savings are dominated by
# raw zips, but the per-read cost on Cool tier for ndjson is also negligible
# given the PS analysis tools' read frequency.
Write-Host "-> Lifecycle policy"
$actions = @{ baseBlob = @{} }
if ($LifecycleCoolAfterDays -gt 0) {
    $actions.baseBlob.tierToCool = @{ daysAfterModificationGreaterThan = $LifecycleCoolAfterDays }
}
if ($LifecycleArchiveAfterDays -gt 0) {
    $actions.baseBlob.tierToArchive = @{ daysAfterModificationGreaterThan = $LifecycleArchiveAfterDays }
}
$lifecyclePolicy = @{
    rules = @(
        @{
            enabled = $true
            name    = "tier-history-blobs"
            type    = "Lifecycle"
            definition = @{
                actions = $actions
                filters = @{
                    blobTypes   = @("blockBlob")
                    prefixMatch = @("$ContainerName/")
                }
            }
        }
    )
} | ConvertTo-Json -Depth 8 -Compress

$policyFile = Join-Path ([IO.Path]::GetTempPath()) "loadtest-lifecycle-$([Guid]::NewGuid()).json"
try {
    $lifecyclePolicy | Out-File -FilePath $policyFile -Encoding utf8 -NoNewline
    az storage account management-policy create `
        --account-name $StorageAccountName `
        -g $HistoryResourceGroup `
        --policy "@$policyFile" | Out-Null
    Write-Host "   set (Cool after $LifecycleCoolAfterDays days, Archive after $LifecycleArchiveAfterDays days)"
}
finally {
    Remove-Item $policyFile -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "History infrastructure ready."
