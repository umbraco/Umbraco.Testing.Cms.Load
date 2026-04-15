# Bootstraps the long-lived "history" infrastructure used to persist load test
# runs and results across pipeline runs. Idempotent — safe to run on every pipeline
# invocation; missing resources are created, existing ones are left alone.
#
# Resources created (in their own RG, never deleted by the test pipeline):
#   - Resource group
#   - Azure Load Testing resource (so run history survives across pipeline runs)
#   - Storage account + blob container (for results NDJSON + raw artifacts)
#
# Storage uses account-key auth for all subsequent operations — avoids RBAC
# propagation delays and works without granting the SP data-plane roles.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$HistoryResourceGroup,
    [Parameter(Mandatory = $true)] [string]$HistoryLocation,
    [Parameter(Mandatory = $true)] [string]$LoadTestName,
    [Parameter(Mandatory = $true)] [string]$StorageAccountName,
    [Parameter(Mandatory = $true)] [string]$ContainerName
)

$ErrorActionPreference = "Stop"

# Ensure the Azure Load Testing CLI extension is present.
# `ubuntu-latest` agents don't always have it pre-installed, and `az load`
# would otherwise fail with "extension not found" on a fresh agent.
az extension add --name load --upgrade --only-show-errors | Out-Null

Write-Host "=== Bootstrapping history infrastructure ==="
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
    az group create -n $HistoryResourceGroup -l $HistoryLocation | Out-Null
    Write-Host "   created"
}

# Azure Load Testing resource
Write-Host "-> Load test resource"
$altExisting = az load show -n $LoadTestName -g $HistoryResourceGroup 2>$null
if ($altExisting) {
    Write-Host "   already exists"
}
else {
    az load create -n $LoadTestName -g $HistoryResourceGroup -l $HistoryLocation | Out-Null
    Write-Host "   created"
}

# Storage account
# Order matters: first check whether we already own it (in the history RG);
# only check global name availability when it doesn't exist for us, so we can
# fail loudly with an actionable error instead of a generic "create failed".
Write-Host "-> Storage account"
$saExisting = az storage account show -n $StorageAccountName -g $HistoryResourceGroup 2>$null
if ($saExisting) {
    Write-Host "   already exists"
}
else {
    $availability = az storage account check-name --name $StorageAccountName | ConvertFrom-Json
    if (-not $availability.nameAvailable) {
        Write-Error @"
Storage account name '$StorageAccountName' is not available globally
($($availability.reason): $($availability.message)).

Override the 'historyStorageAccount' pipeline variable with a globally unique
name (3-24 lowercase alphanumeric characters), then re-run the pipeline.
"@
        exit 1
    }
    az storage account create `
        -n $StorageAccountName `
        -g $HistoryResourceGroup `
        -l $HistoryLocation `
        --sku Standard_LRS `
        --kind StorageV2 `
        --min-tls-version TLS1_2 `
        --allow-blob-public-access false | Out-Null
    Write-Host "   created"
}

# Container — uses account key auth (control-plane only, no data-plane RBAC needed)
Write-Host "-> Container"
$storageKey = az storage account keys list -n $StorageAccountName -g $HistoryResourceGroup --query "[0].value" -o tsv
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

Write-Host ""
Write-Host "History infrastructure ready."
