# Stop every App Service in the test case set. Idempotent on already-stopped apps.

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)] [string]$ResourceGroupName
)

$ErrorActionPreference = "Stop"

if (-not $env:TEST_CASE_OUTPUTS) {
    Write-Error "TEST_CASE_OUTPUTS env var is not set."
    exit 1
}

$cases = $env:TEST_CASE_OUTPUTS | ConvertFrom-Json
$names = @($cases.PSObject.Properties.Name)
if ($names.Count -eq 0) {
    Write-Host "No cases - skipping."
    exit 0
}

foreach ($name in $names) {
    $c = $cases.$name
    Write-Host "Stopping $($c.app_service_name) ($name)"
    az webapp stop -n $c.app_service_name -g $ResourceGroupName | Out-Null
}
