# Idempotently ensure the long-lived "history" infra exists: RG, ALT, storage, container.
# First run creates; subsequent runs no-op. Account-key auth avoids RBAC propagation delays.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$HistoryResourceGroup,
    [Parameter(Mandatory = $true)] [string]$HistoryLocation,
    [Parameter(Mandatory = $true)] [string]$LoadTestName,
    [Parameter(Mandatory = $true)] [string]$StorageAccountName,
    [Parameter(Mandatory = $true)] [string]$ContainerName
)

$ErrorActionPreference = "Stop"

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

# Azure Load Testing resource
Write-Host "-> Load test resource"
$altExisting = az load show -n $LoadTestName -g $HistoryResourceGroup 2>$null
if ($altExisting) {
    Write-Host "   already exists"
}
else {
    az load create -n $LoadTestName -g $HistoryResourceGroup -l $HistoryLocation --tags $tags | Out-Null
    Write-Host "   created"
}

# Storage account: check our RG first; only do the global name-availability check when needed.
Write-Host "-> Storage account"
$saExisting = az storage account show -n $StorageAccountName -g $HistoryResourceGroup 2>$null
if ($saExisting) {
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
