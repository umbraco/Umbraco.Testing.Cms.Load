# Deploy the static dashboard to its Azure Static Web App. Generates a fresh
# read+list SAS scoped to the history container, rewrites dashboard/config.js
# with the actual storage account / container / SAS values, configures CORS
# on the storage account, and uploads via the Static Web Apps CLI.
#
# Run manually after editing dashboard files. Idempotent:
#   - SAS is regenerated on every run; old ones expire naturally.
#   - CORS add is no-op if the rule already exists for that origin.
#   - SWA upload overwrites in place.
#
# Prereqs:
#   - az CLI logged in
#   - SWA CLI installed: npm install -g @azure/static-web-apps-cli
#   - Static Web App already exists (created by ensure-history-infra.ps1
#     when -CreateDashboardSwa is set)

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$HistoryResourceGroup,
    [Parameter(Mandatory = $true)] [string]$StorageAccountName,
    [Parameter(Mandatory = $true)] [string]$ContainerName,
    [Parameter(Mandatory = $true)] [string]$StaticWebAppName,
    [Parameter(Mandatory = $true)] [string]$TenantId,
    [string]$DashboardDir = "$PSScriptRoot/../dashboard",
    [int]$SasExpiryDays = 365
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

if (-not (Test-Path $DashboardDir)) {
    Write-Error "Dashboard directory not found: $DashboardDir"
    exit 1
}

Write-Host "=== Deploying dashboard ==="
Write-Host "  Storage:    $StorageAccountName / $ContainerName"
Write-Host "  Static Web App: $StaticWebAppName"
Write-Host ""

# 1. Generate read+list SAS scoped to the history container.
Write-Host "-> Generating container SAS (read + list, expires in $SasExpiryDays day(s))"
$expiry = (Get-Date).ToUniversalTime().AddDays($SasExpiryDays).ToString("yyyy-MM-ddTHH:mm:ssZ")
$storageKey = az storage account keys list -n $StorageAccountName -g $HistoryResourceGroup --query "[0].value" -o tsv
$sas = az storage container generate-sas `
    --account-name $StorageAccountName `
    --account-key $storageKey `
    --name $ContainerName `
    --permissions rl `
    --expiry $expiry `
    -o tsv

if ([string]::IsNullOrWhiteSpace($sas)) {
    Write-Error "SAS generation failed."
    exit 1
}
Write-Host "   SAS generated (expiry $expiry)"

# 2. Get the SWA's default hostname so we can scope the CORS rule to it.
Write-Host "-> Reading Static Web App hostname"
$swaHostname = az staticwebapp show -n $StaticWebAppName -g $HistoryResourceGroup --query "defaultHostname" -o tsv
if ([string]::IsNullOrWhiteSpace($swaHostname)) {
    Write-Error "Couldn't read defaultHostname from SWA '$StaticWebAppName'."
    exit 1
}
$swaOrigin = "https://$swaHostname"
Write-Host "   $swaOrigin"

# 3. CORS rule on the storage account so the browser can fetch blobs from $swaOrigin.
Write-Host "-> Storage CORS rule"
$existingCors = az storage cors list --services b --account-name $StorageAccountName --account-key $storageKey -o json | ConvertFrom-Json
$alreadyHas = $existingCors | Where-Object { $_.AllowedOrigins -contains $swaOrigin }
if ($alreadyHas) {
    Write-Host "   already configured for $swaOrigin"
}
else {
    az storage cors add `
        --services b `
        --methods GET `
        --origins $swaOrigin `
        --allowed-headers "*" `
        --account-name $StorageAccountName `
        --account-key $storageKey | Out-Null
    Write-Host "   added rule for $swaOrigin"
}

# 4. Rewrite dashboard/config.js + substitute the tenant ID into
#    staticwebapp.config.json. We work on a temp copy so the source-controlled
#    files keep their REPLACE_AT_DEPLOY / __TENANT_ID__ placeholders.
Write-Host "-> Preparing deploy bundle"
$deployTmp = Join-Path ([IO.Path]::GetTempPath()) "loadtest-dashboard-$(Get-Random)"
New-Item -ItemType Directory -Path $deployTmp -Force | Out-Null
Copy-Item -Path "$DashboardDir/*" -Destination $deployTmp -Recurse -Force

$configPath = Join-Path $deployTmp "config.js"
$config = @"
window.DASHBOARD_CONFIG = {
    storageAccount: "$StorageAccountName",
    container:      "$ContainerName",
    sas:            "?$sas"
};
"@
$config | Out-File -FilePath $configPath -Encoding utf8 -Force

$swaConfigPath = Join-Path $deployTmp "staticwebapp.config.json"
if (Test-Path $swaConfigPath) {
    (Get-Content $swaConfigPath -Raw).Replace("__TENANT_ID__", $TenantId) | Out-File -FilePath $swaConfigPath -Encoding utf8 -Force
}

Write-Host "   bundle staged at $deployTmp"

# 5. Upload to SWA via its CLI. (Alternative: az staticwebapp deploy --workspace
#    works too but requires the Bicep deployment-token flow.)
Write-Host "-> Uploading to Static Web App"
$swaToken = az staticwebapp secrets list -n $StaticWebAppName -g $HistoryResourceGroup --query "properties.apiKey" -o tsv
swa deploy $deployTmp --deployment-token $swaToken --env production

Remove-Item -Recurse -Force $deployTmp -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Dashboard deployed: $swaOrigin"
