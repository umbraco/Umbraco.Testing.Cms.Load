#requires -Version 7.3

# Build, publish, and zip-deploy a fresh Umbraco CMS project to the target App
# Service, then poll the seeder status endpoint until seeding completes.
# Invoked from terraform's null_resource.deploy_umbraco local-exec; expects SP
# credentials in env vars (ARM_CLIENT_ID + ARM_TENANT_ID + one of
# ARM_CLIENT_SECRET / ARM_OIDC_TOKEN). Stops the App Service when done so the
# load-test step can start cleanly later.

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)] [string]$ResourceGroupName,
    [Parameter(Mandatory = $true)] [string]$AppServiceName,
    [Parameter(Mandatory = $true)] [string]$AppServiceHostname,
    [Parameter(Mandatory = $true)] [string]$UmbracoVersion,
    [Parameter(Mandatory = $true)] [string]$Scenario,
    [Parameter(Mandatory = $true)] [string]$SeederPreset,
    # File the script writes once the seeder finishes — the load-test job
    # reads it to surface seeder_duration_seconds in the published metrics.
    # On Skipped/Failed seeder, duration_seconds is written as null.
    [Parameter(Mandatory = $true)] [string]$SeederResultPath
)

$ErrorActionPreference = "Stop"

# Make native commands (dotnet, az, Compress-Archive interop) honour $ErrorActionPreference
# so a non-zero exit fails the script instead of silently continuing past a broken build
# or deploy. Requires pwsh 7.3+. Without this, $LASTEXITCODE has to be checked after every
# native command.
$PSNativeCommandUseErrorActionPreference = $true

# ARM_CLIENT_ID + ARM_TENANT_ID are always required; one of ARM_CLIENT_SECRET
# (client-secret auth) or ARM_OIDC_TOKEN (WIF) must also be set.
foreach ($name in @('ARM_CLIENT_ID', 'ARM_TENANT_ID')) {
    if (-not [Environment]::GetEnvironmentVariable($name)) {
        Write-Error "Required env var $name is not set."
        exit 1
    }
}
if (-not $env:ARM_CLIENT_SECRET -and -not $env:ARM_OIDC_TOKEN) {
    Write-Error "Either ARM_CLIENT_SECRET (client-secret auth) or ARM_OIDC_TOKEN (WIF) must be set."
    exit 1
}

# Umbraco.Cms.TestDataSeeder package version per Umbraco major. Update an entry
# here when a new seeder build ships; null means the seeder isn't available yet
# for that major and the run will fail-fast below with a clear message.
# The version is baked into the build cache key, so bumps auto-invalidate stale builds.
$seederPackageVersions = @{
    13 = "13.0.0-beta.1"
    17 = "17.0.0-beta.2"
    # No dedicated v18 build yet; v17 seeder works on v18 (the seeder's surface
    # area is stable across the v17→v18 jump). Bump to a v18 build if/when one
    # ships and the v17 fallback drifts.
    18 = "17.0.0-beta.2"
    # v14/v15/v16: no published seeder yet. resolve-run-config.ps1 fails the
    # run at validation with a clear message; add entries here in lockstep when
    # those builds ship.
}

$umbracoMajor = [int](($UmbracoVersion -split '\.')[0])
$seederPackageVersion = $seederPackageVersions[$umbracoMajor]
if (-not $seederPackageVersion) {
    Write-Error "No Umbraco.Cms.TestDataSeeder version mapped for Umbraco $UmbracoVersion (major $umbracoMajor). Add an entry to `$seederPackageVersions in this script when the package ships for that major."
    exit 1
}

# Captured before Set-Location so finally{} can restore cwd on failure.
$terraformCwd = (Get-Location).Path

$updatedVersionName = $UmbracoVersion.Replace('.', '')
$pathToApp          = "./NewUmbracoProject$updatedVersionName"
$nameToApp          = "NewUmbracoProject$updatedVersionName"
$absoluteBuildDir   = Join-Path $terraformCwd $updatedVersionName

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Deploying Umbraco $UmbracoVersion ($Scenario)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Always build from scratch — the local/shared build cache was removed because
# the time saving didn't materialise in practice. Each pipeline run pays the
# ~5-8 minute build cost once per (version, scenario) the first time it's
# touched. Cleanup happens in the finally{} block regardless of outcome.

# Clean any leftover from a previous failed run, otherwise dotnet new would fail.
if (Test-Path -LiteralPath $updatedVersionName) {
    Write-Host "Cleaning leftover build dir: $updatedVersionName"
    Remove-Item -Recurse -Force -LiteralPath $updatedVersionName
}

try {
    New-Item -ItemType Directory -Path $updatedVersionName -Force | Out-Null
    Set-Location -LiteralPath $updatedVersionName

    # Prerelease and nightly feeds — needed for Umbraco versions not yet on nuget.org.
    # `dotnet nuget add source` returns non-zero when the source name already
    # exists, which would throw under $PSNativeCommandUseErrorActionPreference.
    # Wrap so a re-run on a warm agent (or local-dev re-apply) is a no-op.
    try { dotnet nuget add source "https://www.myget.org/F/umbracoprereleases/api/v3/index.json" -n "Umbraco Prereleases" 2>$null | Out-Null } catch {}
    try { dotnet nuget add source "https://www.myget.org/F/umbraconightly/api/v3/index.json" -n "Umbraco Nightly" 2>$null | Out-Null } catch {}

    Write-Host "Installing Umbraco.Templates::$UmbracoVersion..."
    dotnet new install Umbraco.Templates::$UmbracoVersion

    Write-Host "Creating new Umbraco project: $nameToApp..."
    dotnet new umbraco -n $nameToApp

    Set-Location -LiteralPath $nameToApp

    Write-Host "Adding Umbraco.Cms.TestDataSeeder $seederPackageVersion..."
    dotnet add package Umbraco.Cms.TestDataSeeder --version $seederPackageVersion
    if ($LASTEXITCODE -ne 0) {
        Write-Error "dotnet add package Umbraco.Cms.TestDataSeeder failed (exit $LASTEXITCODE)."
        exit 1
    }

    # Copy scenario code overlay (everything except appsettings.json) into the project tree.
    $additionalSetupCandidate = Join-Path $terraformCwd "../loadtests/scenarios/$Scenario/AdditionalSetup"
    $resolvedAdditional = $null
    if (Test-Path -LiteralPath $additionalSetupCandidate) {
        $resolvedAdditional = (Resolve-Path -LiteralPath $additionalSetupCandidate).Path
    }

    if ($resolvedAdditional) {
        $overlayFiles = @(Get-ChildItem -Path $resolvedAdditional -Recurse -File |
            Where-Object { $_.Name -ne 'appsettings.json' })

        if ($overlayFiles.Count -gt 0) {
            Write-Host ""
            Write-Host "Applying scenario '$Scenario' code overlay ($($overlayFiles.Count) file(s))..." -ForegroundColor Cyan
            $projectRoot = (Get-Location).Path
            foreach ($f in $overlayFiles) {
                $rel = $f.FullName.Substring($resolvedAdditional.Length).TrimStart([IO.Path]::DirectorySeparatorChar, '/', '\')
                $dest = Join-Path $projectRoot $rel
                $destDir = Split-Path -Parent $dest
                if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
                    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                }
                Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
                Write-Host "  + $rel"
            }
        } else {
            Write-Host "Scenario '$Scenario' has no code-overlay files."
        }
    }
    else {
        Write-Host "Scenario '$Scenario' has no AdditionalSetup folder - skipping code overlay."
    }

    Write-Host "Building project..."
    dotnet build --configuration Release

    Set-Location -LiteralPath ..

    Write-Host "Publishing application..."
    dotnet publish $pathToApp -c Release -o $pathToApp/publish

    Write-Host "Creating deployment package..."
    Compress-Archive -Path $pathToApp/publish/* -DestinationPath $pathToApp/publish.zip -Force

    # Auth + deploy happen INSIDE the try block so publish.zip is still present
    # (the finally cleanup below removes the whole build dir). Previously the
    # build cache kept a copy of the zip outside the build dir; without the
    # cache, we must complete the deploy before tearing down the build tree.
    Set-Location -LiteralPath $terraformCwd

    # WIF (federated token) takes priority over client-secret auth when both are set.
    Write-Host "Authenticating to Azure..."
    if ($env:ARM_OIDC_TOKEN) {
        az login --service-principal --username $env:ARM_CLIENT_ID --tenant $env:ARM_TENANT_ID --federated-token $env:ARM_OIDC_TOKEN | Out-Null
    } else {
        az login --service-principal --username $env:ARM_CLIENT_ID --password $env:ARM_CLIENT_SECRET --tenant $env:ARM_TENANT_ID | Out-Null
    }

    # Pin the subscription explicitly — `az login` defaults to whichever sub the SP
    # happens to land on, which for multi-sub SPs is not necessarily the one Terraform
    # just provisioned the App Service in. ARM_SUBSCRIPTION_ID is set by the pipeline
    # and inherits into this local-exec process.
    if ($env:ARM_SUBSCRIPTION_ID) {
        az account set --subscription $env:ARM_SUBSCRIPTION_ID
    } else {
        Write-Warning "ARM_SUBSCRIPTION_ID not set; deploy will target the SP's default subscription."
    }

    $deployZip = Join-Path $absoluteBuildDir "$nameToApp/publish.zip"
    Write-Host "Deploying to App Service: $AppServiceName..."
    az webapp deployment source config-zip --src $deployZip -n $AppServiceName -g $ResourceGroupName
}
finally {
    # Restore cwd and clean the build dir on every path (success and failure).
    Set-Location -LiteralPath $terraformCwd -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $absoluteBuildDir) {
        Write-Host "Cleaning up build artifacts..."
        Remove-Item -Recurse -Force -LiteralPath $absoluteBuildDir -ErrorAction SilentlyContinue
    }
}

function Write-SeederResult {
    param(
        [Parameter(Mandatory)] [string]$Status,
        [Nullable[double]]$DurationSeconds = $null
    )
    $payload = [ordered]@{
        status           = $Status
        duration_seconds = $DurationSeconds
    }
    $dir = Split-Path -Parent $SeederResultPath
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $payload | ConvertTo-Json -Compress | Set-Content -Path $SeederResultPath -Encoding utf8
}

# Wait for the data seeder to finish. The polling doubles as App Service warm-up.
$seederStatusUrl = "https://$AppServiceHostname/umbraco/api/seederstatus/status"
$maxAttemptsByPreset = @{ Small = 60; Medium = 180; Large = 360; Massive = 720 }   # 10/30/60/120 min at 10s cadence
$maxAttempts = $maxAttemptsByPreset[$SeederPreset] ?? 360
Write-Host "Seeder timeout for preset '$SeederPreset': $($maxAttempts * 10 / 60) minutes."
$attempt = 0
$seederComplete = $false
$seederSuccess  = $false

Write-Host ""
Write-Host "Waiting for data seeder to complete..." -ForegroundColor Yellow

while ($attempt -lt $maxAttempts -and -not $seederComplete) {
    Start-Sleep -Seconds 10
    $attempt++

    try {
        # -SkipHttpErrorCheck so 503 lands here, not in catch{}.
        $response = Invoke-WebRequest -Uri $seederStatusUrl -UseBasicParsing -TimeoutSec 30 -SkipHttpErrorCheck
        $seederStatusCode = $response.StatusCode

        # Parse the body in its own guard. A non-JSON 5xx (App Service warmup
        # HTML, gateway error page) would otherwise fall into the outer catch
        # and get misreported as "Waiting for seeder endpoint..." for the full
        # timeout budget — hiding the real failure for up to 120 minutes on
        # the Massive preset.
        try {
            $responseBody = $response.Content | ConvertFrom-Json
        } catch {
            Write-Host "  [$attempt/$maxAttempts] HTTP $seederStatusCode (non-JSON body); retrying..."
            continue
        }

        # Terminal-OK states: Completed, CompletedWithErrors, Skipped.
        if ($seederStatusCode -eq 200 -and $responseBody.Status -in @("Completed", "CompletedWithErrors", "Skipped")) {
            Write-Host ""
            if ($responseBody.Status -eq "Skipped") {
                Write-Host "Data seeder was disabled in scenario config - skipping wait." -ForegroundColor Green
                Write-SeederResult -Status "Skipped"
            } else {
                $elapsedSeconds = [math]::Round($responseBody.ElapsedMs / 1000, 2)
                $verb = ($responseBody.Status -eq "CompletedWithErrors") ? "completed with errors" : "completed successfully"
                Write-Host "Data seeder $verb!" -ForegroundColor Green
                Write-Host "  Duration: $elapsedSeconds seconds"
                Write-Host "  Executed: $($responseBody.ExecutedCount)"
                Write-Host "  Failed: $($responseBody.FailedCount)"
                Write-SeederResult -Status $responseBody.Status -DurationSeconds $elapsedSeconds
            }
            $seederComplete = $true
            $seederSuccess = $true
        }
        elseif ($seederStatusCode -eq 503) {
            Write-Host ""
            Write-Host "ERROR: Seeder reported failure - $($responseBody.ErrorMessage)" -ForegroundColor Red
            Write-SeederResult -Status "Failed"
            $seederComplete = $true
        }
        else {
            $status = if ($responseBody.CurrentSeeder) { $responseBody.CurrentSeeder } else { $responseBody.Status }
            Write-Host "  [$attempt/$maxAttempts] Status: $status"
        }
    }
    catch {
        Write-Host "  [$attempt/$maxAttempts] Waiting for seeder endpoint..."
    }
}

# Best-effort `az webapp stop` with retries. Azure's management API can return
# a transient 503 ('Service Unavailable') right after a deployment finishes,
# even though the resource is healthy. Retrying with short backoff handles the
# common case; if all retries fail, log a warning and continue — the App
# Service stays running but the load-test stage's `az webapp start` is
# idempotent, so nothing functional breaks downstream.
function Stop-AppServiceBestEffort {
    param([Parameter(Mandatory)] [string]$Name, [Parameter(Mandatory)] [string]$ResourceGroup)
    $delays = @(5, 10, 20)
    for ($i = 0; $i -lt $delays.Count; $i++) {
        $prevPref = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
        try {
            az webapp stop -n $Name -g $ResourceGroup
            $exit = $LASTEXITCODE
        } finally {
            $PSNativeCommandUseErrorActionPreference = $prevPref
        }
        if ($exit -eq 0) { return $true }
        $isLast = ($i -eq $delays.Count - 1)
        if ($isLast) {
            Write-Host "##vso[task.logissue type=warning]az webapp stop failed after $($delays.Count) attempts (last exit $exit). App Service stays running until the load-test stage starts it."
            return $false
        }
        Write-Host "  az webapp stop exit $exit; retrying in $($delays[$i])s..."
        Start-Sleep -Seconds $delays[$i]
    }
    return $false
}

if (-not $seederSuccess) {
    Write-Host ""
    Write-Host "Seeder did not complete - stopping App Service and exiting non-zero" -ForegroundColor Red
    # 503 path already wrote 'Failed'; this catches the loop-timeout case.
    if (-not (Test-Path $SeederResultPath)) {
        Write-SeederResult -Status "TimedOut"
    }
    Stop-AppServiceBestEffort -Name $AppServiceName -ResourceGroup $ResourceGroupName | Out-Null
    exit 1
}

# Stop the app service until the load-test step starts it again.
Write-Host ""
Write-Host "Stopping App Service until load test..." -ForegroundColor Cyan
Stop-AppServiceBestEffort -Name $AppServiceName -ResourceGroup $ResourceGroupName | Out-Null

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "Deployment complete: $UmbracoVersion" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
