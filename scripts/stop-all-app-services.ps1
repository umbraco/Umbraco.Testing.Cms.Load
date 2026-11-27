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
# A failure on one app continues to the next, and is only a warning, except
# for a sibling on the same plan as the case about to start: that fails the
# step once every app has been tried, so the case is not measured alongside
# it. Idempotent on already-stopped apps. Each stop is tried up to $Attempts times, because Azure
# Resource Manager answers the odd call with a transient error (build 306594:
# BadGatewayConnection for 'Microsoft.Web' on a start between two cases). In
# the pre-test sweep a sibling left running would share the plan with the case
# being measured, so one transient error is worth a second try.

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)] [string]$ResourceGroupName,
    [string]$ExceptAppService,
    [ValidateRange(1, 10)] [int]$Attempts = 3,
    # Wait before the second attempt; doubled before each one after that.
    [ValidateRange(0, 120)] [int]$RetryDelaySeconds = 10
)

$ErrorActionPreference = "Stop"

# Explicitly OFF: the loop below needs a failed `az webapp stop` to set
# $LASTEXITCODE rather than throw. Every sibling script sets this to $true, so
# leaving it implicit is one consistency edit away from a fail-fast sweep.
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

# The plan the current case runs on. A sibling on that plan that will not stop
# would be measured along with the case, so that one fails the step; a sibling
# on another plan cannot affect the measurement and only gets a warning.
$currentPlan = $null
if ($ExceptAppService) {
    $current = @($names | ForEach-Object { $cases.$_ } | Where-Object { $_.app_service_name -eq $ExceptAppService })
    if ($current.Count -gt 0) { $currentPlan = [string]$current[0].app_service_plan_id }
}

$samePlanFailures = [System.Collections.Generic.List[string]]::new()
foreach ($name in $names) {
    $c = $cases.$name
    if ($ExceptAppService -and $c.app_service_name -eq $ExceptAppService) {
        Write-Host "Skipping $($c.app_service_name) (current case)"
        continue
    }
    Write-Host "Stopping $($c.app_service_name) ($name)"
    $delay = $RetryDelaySeconds
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        az webapp stop -n $c.app_service_name -g $ResourceGroupName | Out-Null
        if ($LASTEXITCODE -eq 0) { break }
        if ($attempt -lt $Attempts) {
            Write-Warning "  -> stop failed for $($c.app_service_name) (exit $LASTEXITCODE, attempt $attempt of $Attempts); retrying in $delay s."
            Start-Sleep -Seconds $delay
            $delay *= 2
        } elseif ($currentPlan -and [string]$c.app_service_plan_id -eq $currentPlan) {
            Write-Warning "  -> stop failed for $($c.app_service_name) (exit $LASTEXITCODE) after $Attempts attempts; it shares the plan of the case about to be measured."
            $samePlanFailures.Add("$($c.app_service_name) ($name)")
        } else {
            Write-Warning "  -> stop failed for $($c.app_service_name) (exit $LASTEXITCODE) after $Attempts attempts; on another plan, continuing."
        }
    }
}

if ($samePlanFailures.Count -gt 0) {
    Write-PipelineError "Could not stop $($samePlanFailures -join ', ') on the plan $ExceptAppService runs on; measuring now would count its work as well. Not starting the case."
}
# Explicit: otherwise the step's exit code is that of the last az call, which
# is non-zero when the last app in the list failed to stop.
exit 0
