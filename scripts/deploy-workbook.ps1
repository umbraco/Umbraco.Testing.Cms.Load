# Deploy the load-test Workbook to Azure. Idempotent: re-running with the same
# -WorkbookId updates in place; changing -WorkbookId creates a new Workbook
# (and orphans the previous one).
#
# Run this:
#   - whenever dashboards/loadtest.workbook.json changes
#   - on first-time provisioning, after ensure-monitoring-infra.ps1 has run
#
# Prereqs:
#   - az CLI logged in
#   - Log Analytics workspace already exists (created by ensure-monitoring-infra.ps1)

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$HistoryResourceGroup,
    [Parameter(Mandatory = $true)] [string]$HistoryLocation,
    [Parameter(Mandatory = $true)] [string]$WorkspaceName,
    [string]$WorkbookJsonPath = "$PSScriptRoot/../dashboards/loadtest.workbook.json",
    [string]$DisplayName = "Umbraco Load Tests",
    # Stable GUID — re-running this script with the same value updates the
    # existing Workbook in place. Changing it creates a NEW Workbook and the
    # old one becomes orphaned. Override only if you want to deploy multiple
    # variants side-by-side.
    [string]$WorkbookId = "5b9c2f7e-3a4d-4f1b-9e8a-2b7c1f3d4e5a"
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

if (-not (Test-Path $WorkbookJsonPath)) {
    Write-Error "Workbook JSON not found at: $WorkbookJsonPath"
    exit 1
}

Write-Host "=== Deploying Workbook ==="
Write-Host "  RG:           $HistoryResourceGroup"
Write-Host "  Workspace:    $WorkspaceName"
Write-Host "  Display name: $DisplayName"
Write-Host "  Workbook ID:  $WorkbookId"
Write-Host "  JSON source:  $WorkbookJsonPath"
Write-Host ""

# Validate the JSON parses before we ship it. Saves a round-trip if someone
# left a trailing comma in the file.
try {
    Get-Content $WorkbookJsonPath -Raw | ConvertFrom-Json | Out-Null
}
catch {
    Write-Error "Workbook JSON is invalid: $($_.Exception.Message)"
    exit 1
}

$subId = az account show --query id -o tsv

$workspaceId = az monitor log-analytics workspace show -n $WorkspaceName -g $HistoryResourceGroup --query id -o tsv
if ([string]::IsNullOrWhiteSpace($workspaceId)) {
    Write-Error "Couldn't resolve workspace '$WorkspaceName' in RG '$HistoryResourceGroup'. Run ensure-monitoring-infra.ps1 first."
    exit 1
}

# serializedData is the Workbook content as a *string* embedded in the
# resource body. ConvertTo-Json will escape it correctly when we serialize
# the outer body below.
#
# We substitute __WORKSPACE_ID__ → the actual workspace ARM resource ID so
# the Workspace parameter ships with a default value baked in. Resource
# pickers (type 5) need an explicit `value` to auto-fill on first open;
# `showDefault: true` alone only adds a "Default" option, doesn't select it.
$workbookContent = (Get-Content $WorkbookJsonPath -Raw).Replace("__WORKSPACE_ID__", $workspaceId)

$body = @{
    kind     = "shared"
    location = $HistoryLocation
    tags     = @{ project = "umbraco-loadtest"; managed_by = "ensure-script" }
    properties = @{
        displayName    = $DisplayName
        serializedData = $workbookContent
        version        = "Notebook/1.0"
        category       = "workbook"
        sourceId       = $workspaceId
    }
} | ConvertTo-Json -Depth 8 -Compress

$workbookPath = "/subscriptions/$subId/resourceGroups/$HistoryResourceGroup/providers/Microsoft.Insights/workbooks/${WorkbookId}?api-version=2022-04-01"
$bodyFile = Join-Path ([IO.Path]::GetTempPath()) "loadtest-workbook-$([Guid]::NewGuid()).json"
try {
    $body | Out-File -FilePath $bodyFile -Encoding utf8 -NoNewline
    az rest --method put --url "https://management.azure.com$workbookPath" --body "@$bodyFile" --headers "Content-Type=application/json" | Out-Null
}
finally {
    Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue
}

# Build the portal URL so the user can click straight to it.
$portalUrl = "https://portal.azure.com/#@/resource/subscriptions/$subId/resourceGroups/$HistoryResourceGroup/providers/Microsoft.Insights/workbooks/$WorkbookId/workbook"

Write-Host ""
Write-Host "Workbook deployed."
Write-Host "  Portal: $portalUrl"
Write-Host ""
Write-Host "Tip: pin the Workbook to your Azure portal dashboard so you can land on it from portal.azure.com without navigating."
