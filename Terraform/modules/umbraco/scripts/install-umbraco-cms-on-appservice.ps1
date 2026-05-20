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

# Hash the scenario's AdditionalSetup folder so a code-overlay edit (e.g.
# Program.cs) invalidates the cache. Manifest is "{relpath}={file-sha}|..."
# so renames also invalidate. appsettings.json edits invalidate too — slight
# over-invalidation since appsettings is applied at the App Service level
# (not baked into the binary), but the extra rebuild is quick and the simpler
# cache key beats teaching the function which files matter.
function Get-OverlayHash([string] $rootPath) {
    if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) { return "noverlay" }
    # Canonicalize so $_.FullName below shares the same form (no `..` segments)
    # and Substring math gives a clean relative path.
    $rootPath = (Resolve-Path -LiteralPath $rootPath).Path
    $files = @(Get-ChildItem -Path $rootPath -Recurse -File | Sort-Object FullName)
    if ($files.Count -eq 0) { return "empty" }
    $manifest = ($files | ForEach-Object {
        $rel = $_.FullName.Substring($rootPath.Length)
        $h   = (Get-FileHash -Path $_.FullName -Algorithm SHA256).Hash
        "$rel=$h"
    }) -join "|"
    $stream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($manifest))
    try {
        return (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash.Substring(0, 12)
    } finally {
        $stream.Dispose()
    }
}

$additionalSetupPath = Join-Path $terraformCwd "../loadtests/scenarios/$Scenario/AdditionalSetup"
$overlayHash         = Get-OverlayHash $additionalSetupPath

# Build artifact cache. Identical (version, scenario, seeder-package, overlay-hash)
# combos produce identical binaries; reusing the zip across same-build cases on
# different tiers eliminates per-case build noise (NuGet restore order, compiler
# timestamp jitter) so a tier comparison only varies infra, not the binary under
# test. Bumping the seeder package, editing the scenario overlay, or changing the
# Umbraco version all auto-invalidate the cache.
$cacheDir     = Join-Path $terraformCwd ".build-cache"
$safeCacheKey = "${UmbracoVersion}__${Scenario}__seeder-${seederPackageVersion}__overlay-${overlayHash}" -replace '[^A-Za-z0-9._-]', '-'
$cachedZip    = Join-Path $cacheDir "$safeCacheKey.zip"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Deploying Umbraco $UmbracoVersion ($Scenario)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Shared build cache (history-RG storage). The local .build-cache/ folder only
# survives within a single pipeline run — fresh hosted agents start empty, so
# every run currently re-runs `dotnet publish` for the first case of each
# (version, scenario) combination. Promoting cache zips to history storage and
# downloading them on demand removes that minute-tax across runs. Gated on the
# three BUILD_CACHE_* env vars (set by the pipeline's Terraform Apply task); a
# missing env var just falls through to the existing local-cache-only path.
if (-not (Test-Path -LiteralPath $cachedZip) -and
    $env:BUILD_CACHE_STORAGE_ACCOUNT -and
    $env:BUILD_CACHE_STORAGE_KEY -and
    $env:BUILD_CACHE_CONTAINER) {
    Write-Host "Local build cache miss; checking shared cache in $($env:BUILD_CACHE_STORAGE_ACCOUNT)..."
    if (-not (Test-Path -LiteralPath $cacheDir)) {
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    }
    # Disable throw-on-nonzero locally so we can branch on $LASTEXITCODE — az's
    # exit code is the cleanest "is this blob there" signal.
    $prevPref = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        az storage blob download `
            --account-name $env:BUILD_CACHE_STORAGE_ACCOUNT `
            --account-key $env:BUILD_CACHE_STORAGE_KEY `
            --container-name $env:BUILD_CACHE_CONTAINER `
            --name "build-cache/$safeCacheKey.zip" `
            --file $cachedZip `
            --no-progress 2>$null | Out-Null
        $downloadExit = $LASTEXITCODE
    } finally {
        $PSNativeCommandUseErrorActionPreference = $prevPref
    }
    if ($downloadExit -eq 0 -and (Test-Path -LiteralPath $cachedZip)) {
        Write-Host "Shared cache HIT: downloaded build-cache/$safeCacheKey.zip" -ForegroundColor Green
    } else {
        # Remove partial file so the build path runs cleanly.
        Remove-Item -LiteralPath $cachedZip -Force -ErrorAction SilentlyContinue
        Write-Host "Shared cache MISS: build-cache/$safeCacheKey.zip not found (or download failed)."
    }
}

if (Test-Path -LiteralPath $cachedZip) {
    Write-Host "Build cache HIT: reusing $cachedZip" -ForegroundColor Green
}
else {
    Write-Host "Build cache MISS: building from scratch."

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

        # Promote the zip into the cache so sibling cases (same version+scenario,
        # different tier) skip the build and deploy this exact artifact.
        if (-not (Test-Path -LiteralPath $cacheDir)) {
            New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        }
        Copy-Item -LiteralPath "$pathToApp/publish.zip" -Destination $cachedZip -Force
        Write-Host "Cached build artifact at: $cachedZip"

        # Promote to shared cache so the next pipeline run on a fresh agent (or
        # a sibling case in this run that hits the cache after we cleared the
        # local copy) skips the build entirely. Failure is non-fatal — the
        # local cache still serves same-run siblings, and the next-build path
        # is correct, just slower.
        if ($env:BUILD_CACHE_STORAGE_ACCOUNT -and $env:BUILD_CACHE_STORAGE_KEY -and $env:BUILD_CACHE_CONTAINER) {
            Write-Host "Uploading build to shared cache..."
            $prevPref = $PSNativeCommandUseErrorActionPreference
            $PSNativeCommandUseErrorActionPreference = $false
            try {
                az storage blob upload `
                    --account-name $env:BUILD_CACHE_STORAGE_ACCOUNT `
                    --account-key $env:BUILD_CACHE_STORAGE_KEY `
                    --container-name $env:BUILD_CACHE_CONTAINER `
                    --file $cachedZip `
                    --name "build-cache/$safeCacheKey.zip" `
                    --overwrite `
                    --no-progress 2>$null | Out-Null
                $uploadExit = $LASTEXITCODE
            } finally {
                $PSNativeCommandUseErrorActionPreference = $prevPref
            }
            if ($uploadExit -eq 0) {
                Write-Host "Shared cache updated: build-cache/$safeCacheKey.zip"
            } else {
                Write-Host "Shared cache upload failed (exit $uploadExit) — local cache still good for siblings in this run."
            }
        }
    }
    finally {
        # Restore cwd and clean the build dir on every path (success and failure).
        # The cache zip lives outside the build dir so it survives this cleanup.
        Set-Location -LiteralPath $terraformCwd -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $absoluteBuildDir) {
            Write-Host "Cleaning up build artifacts..."
            Remove-Item -Recurse -Force -LiteralPath $absoluteBuildDir -ErrorAction SilentlyContinue
        }
    }
}

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

Write-Host "Deploying to App Service: $AppServiceName..."
az webapp deployment source config-zip --src $cachedZip -n $AppServiceName -g $ResourceGroupName

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

if (-not $seederSuccess) {
    Write-Host ""
    Write-Host "Seeder did not complete - stopping App Service and exiting non-zero" -ForegroundColor Red
    # 503 path already wrote 'Failed'; this catches the loop-timeout case.
    if (-not (Test-Path $SeederResultPath)) {
        Write-SeederResult -Status "TimedOut"
    }
    az webapp stop -n $AppServiceName -g $ResourceGroupName
    exit 1
}

# Stop the app service until the load-test step starts it again.
Write-Host ""
Write-Host "Stopping App Service until load test..." -ForegroundColor Cyan
az webapp stop -n $AppServiceName -g $ResourceGroupName

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "Deployment complete: $UmbracoVersion" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
