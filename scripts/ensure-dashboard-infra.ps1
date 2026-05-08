# Idempotently ensure the long-lived dashboard infra exists: an Azure Static
# Web App (Free tier) in the history resource group, with Entra-ID auth wired
# up via the staticwebapp.config.json shipped with the dashboard.
#
# Run once per environment (or any time you want to verify the SWA still
# exists). Subsequent runs are no-ops.
#
# Prereqs:
#   - az CLI logged in
#   - History RG already exists (created by ensure-history-infra.ps1)
#   - Entra-ID app registration exists with redirect URI
#     https://<swa-hostname>/.auth/login/aad/callback
#     (one-time portal task: pass the resulting client ID + secret here)

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$HistoryResourceGroup,
    [Parameter(Mandatory = $true)] [string]$HistoryLocation,
    [Parameter(Mandatory = $true)] [string]$StaticWebAppName,
    [Parameter(Mandatory = $true)] [string]$AadClientId,
    [Parameter(Mandatory = $true)] [securestring]$AadClientSecret
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

$tags = @("project=umbraco-loadtest", "managed_by=ensure-script")

Write-Host "=== Ensuring dashboard infrastructure ==="
Write-Host "  RG:              $HistoryResourceGroup"
Write-Host "  Location:        $HistoryLocation"
Write-Host "  Static Web App:  $StaticWebAppName"
Write-Host ""

# Reuse the existence-check helper pattern from ensure-history-infra.ps1.
function Test-AzResource([scriptblock] $Probe) {
    try {
        $result = & $Probe 2>$null
        return [bool]$result
    } catch {
        return $false
    }
}

# Static Web App
Write-Host "-> Static Web App"
if (Test-AzResource { az staticwebapp show -n $StaticWebAppName -g $HistoryResourceGroup }) {
    Write-Host "   already exists"
}
else {
    # SWA Free tier supports the auth gate we need; no source-control integration
    # required (we deploy via SWA CLI from deploy-dashboard.ps1).
    az staticwebapp create `
        -n $StaticWebAppName `
        -g $HistoryResourceGroup `
        -l $HistoryLocation `
        --sku Free `
        --tags $tags | Out-Null
    Write-Host "   created"
}

# Capture the default hostname for the redirect-URI reminder.
$swaHostname = az staticwebapp show -n $StaticWebAppName -g $HistoryResourceGroup --query "defaultHostname" -o tsv

# App settings — the names referenced by staticwebapp.config.json's
# clientIdSettingName / clientSecretSettingName.
Write-Host "-> App settings (Entra-ID auth secrets)"
$plainSecret = [System.Net.NetworkCredential]::new("", $AadClientSecret).Password
az staticwebapp appsettings set `
    -n $StaticWebAppName `
    -g $HistoryResourceGroup `
    --setting-names "AAD_CLIENT_ID=$AadClientId" "AAD_CLIENT_SECRET=$plainSecret" | Out-Null
Write-Host "   set"

Write-Host ""
Write-Host "Dashboard SWA ready: https://$swaHostname"
Write-Host ""
Write-Host "One-time Entra-ID configuration check:"
Write-Host "  - In the app registration, confirm the redirect URI is set to:"
Write-Host "      https://$swaHostname/.auth/login/aad/callback"
Write-Host "  - Without this, the auth flow loops back to the login page."
