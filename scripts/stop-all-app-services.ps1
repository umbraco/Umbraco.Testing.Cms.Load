# Stop every App Service in the test case set, optionally skipping one.
#
# Used in two places:
#   1. End-of-run sweep (no -ExceptAppService) so nothing runs idle during the
#      manual validation window.
#   2. Pre-test sweep (with -ExceptAppService = the case about to start) so
#      same-tier siblings can't contaminate the current case's measurement —
#      replaces the previous "stop previous in chain" pattern that depended on
#      every case emitting its terraform output (a partial apply could break
#      the chain and leave a sibling hot during measurement).
#
# Best-effort: a failure on one app continues to the next. $ErrorActionPreference
# stays "Stop" only for cmdlet errors (json parse, etc.); native `az webapp stop`
# non-zero exits don't trigger Stop in pwsh < 7.3, which is the desired behaviour
# here. Idempotent on already-stopped apps.

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)] [string]$ResourceGroupName,
    [string]$ExceptAppService
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
    if ($ExceptAppService -and $c.app_service_name -eq $ExceptAppService) {
        Write-Host "Skipping $($c.app_service_name) (current case)"
        continue
    }
    Write-Host "Stopping $($c.app_service_name) ($name)"
    az webapp stop -n $c.app_service_name -g $ResourceGroupName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "  -> stop failed for $($c.app_service_name) (exit $LASTEXITCODE); continuing."
    }
}
