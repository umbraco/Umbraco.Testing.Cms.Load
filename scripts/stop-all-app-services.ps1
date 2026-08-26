#requires -Version 7.3

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
# Best-effort: a failure on one app continues to the next. Idempotent on
# already-stopped apps.

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)] [string]$ResourceGroupName,
    [string]$ExceptAppService
)

$ErrorActionPreference = "Stop"

# Explicitly OFF, not merely left at its default. This script's best-effort loop
# depends on a failing `az webapp stop` returning a non-zero $LASTEXITCODE
# instead of throwing — every sibling script in this folder sets this to $true,
# so relying on the implicit default made the behaviour one consistency edit (or
# one changed pwsh default) away from silently becoming fail-fast, aborting the
# sweep on the first app that won't stop. $ErrorActionPreference stays "Stop" so
# cmdlet errors (JSON parse, etc.) still fail loudly.
$PSNativeCommandUseErrorActionPreference = $false

. "$PSScriptRoot/_helpers.ps1"

if (-not $env:TEST_CASE_OUTPUTS) {
    Write-PipelineError "TEST_CASE_OUTPUTS env var is not set."
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
