# Smoke-verify deployed App Services on a skipLoadTests=true run.
# For each case: start, poll homepage for 200, check seeder status, stop.
# Exits non-zero if any case fails.

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
$failed = @()

foreach ($prop in $cases.PSObject.Properties) {
    $testCaseId = $prop.Name
    $c = $prop.Value
    if ([string]::IsNullOrWhiteSpace($c.hostname)) { continue }

    Write-Host "=== Verifying $testCaseId ($($c.hostname)) ==="
    az webapp start -n $c.app_service_name -g $ResourceGroupName | Out-Null

    $deadline = (Get-Date).AddMinutes(3)
    $homeOk   = $false
    $seederOk = $false

    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri "https://$($c.hostname)" -UseBasicParsing -DisableKeepAlive -TimeoutSec 15
            if ($r.StatusCode -eq 200) { Write-Host "  -> homepage 200 OK"; $homeOk = $true; break }
            Write-Host "  status=$($r.StatusCode), retrying..."
        } catch {
            Write-Host "  not ready yet ($($_.Exception.Message.Split([Environment]::NewLine)[0]))"
        }
        Start-Sleep -Seconds 5
    }

    # Terminal-OK seeder states: Completed, CompletedWithErrors, Skipped.
    if ($homeOk) {
        try {
            $sr = Invoke-WebRequest -Uri "https://$($c.hostname)/umbraco/api/seederstatus/status" -UseBasicParsing -DisableKeepAlive -TimeoutSec 30 -SkipHttpErrorCheck
            $body = $sr.Content | ConvertFrom-Json
            if ($sr.StatusCode -eq 200 -and $body.Status -in @('Completed', 'CompletedWithErrors', 'Skipped')) {
                Write-Host "  -> seeder $($body.Status)"
                $seederOk = $true
            } else {
                Write-Host "  -> seeder status=$($body.Status) statusCode=$($sr.StatusCode)"
            }
        } catch {
            Write-Host "  -> seeder status endpoint unreachable: $($_.Exception.Message.Split([Environment]::NewLine)[0])"
        }
    }

    az webapp stop -n $c.app_service_name -g $ResourceGroupName | Out-Null
    if (-not ($homeOk -and $seederOk)) { $failed += $testCaseId }
}

if ($failed.Count -gt 0) {
    Write-Host "##vso[task.logissue type=error]Smoke verify failed for: $($failed -join ', ')"
    exit 1
}

Write-Host "All deployed sites responded 200."
