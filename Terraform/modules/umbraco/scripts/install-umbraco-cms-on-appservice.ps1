[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)] [string]$ResourceGroupName,
    [Parameter(Mandatory = $true)] [string]$AppServiceName,
    [Parameter(Mandatory = $true)] [string]$AppServiceHostname,
    [Parameter(Mandatory = $true)] [string]$UmbracoVersion,
    [Parameter(Mandatory = $true)] [string]$Scenario,
    [Parameter(Mandatory = $true)] [string]$SeederPreset
)

$ErrorActionPreference = "Stop"

# SP credentials come from terraform local-exec env vars; check they're set.
foreach ($name in @('ARM_CLIENT_ID', 'ARM_CLIENT_SECRET', 'ARM_TENANT_ID')) {
    if (-not [Environment]::GetEnvironmentVariable($name)) {
        Write-Error "Required env var $name is not set."
        exit 1
    }
}

# Capture cwd before Set-Location so finally{} can restore it.
$terraformCwd = (Get-Location).Path

# Remove dots from Umbraco version for folder naming.
$updatedVersionName = $UmbracoVersion.Replace('.', '')
$pathToApp          = "./NewUmbracoProject$updatedVersionName"
$nameToApp          = "NewUmbracoProject$updatedVersionName"
$absoluteBuildDir   = Join-Path $terraformCwd $updatedVersionName

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Deploying Umbraco $UmbracoVersion" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Clean any leftover from a previous failed run, otherwise dotnet new would fail.
if (Test-Path -LiteralPath $updatedVersionName) {
    Write-Host "Cleaning leftover build dir: $updatedVersionName"
    Remove-Item -Recurse -Force -LiteralPath $updatedVersionName
}

try {
    # Create a new folder for Umbraco Template installation.
    New-Item -ItemType Directory -Path $updatedVersionName -Force | Out-Null
    Set-Location -LiteralPath $updatedVersionName

    # Add nuget package sources for Umbraco prereleases and nightly builds.
    dotnet nuget add source "https://www.myget.org/F/umbracoprereleases/api/v3/index.json" -n "Umbraco Prereleases" 2>$null
    dotnet nuget add source "https://www.myget.org/F/umbraconightly/api/v3/index.json" -n "Umbraco Nightly" 2>$null

    # Install Umbraco template and create the project.
    Write-Host "Installing Umbraco.Templates::$UmbracoVersion..."
    dotnet new install Umbraco.Templates::$UmbracoVersion

    Write-Host "Creating new Umbraco project: $nameToApp..."
    dotnet new umbraco -n $nameToApp

    Set-Location -LiteralPath $nameToApp

    # Add the test data seeder package; major aligns with the Umbraco major.
    $majorVersion = [int]($UmbracoVersion -split '\.')[0]
    Write-Host "Adding Umbraco.Cms.TestDataSeeder package for Umbraco $majorVersion..."
    dotnet add package Umbraco.Cms.TestDataSeeder --version "$majorVersion.*" --prerelease

    # Add the Clean starter kit so the homepage has real templates + sample content to render.
    # NuGet picks the latest version compatible with the Umbraco major.
    Write-Host "Adding Clean starter kit..."
    dotnet add package clean

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

    # Build the project.
    Write-Host "Building project..."
    dotnet build --configuration Release

    Set-Location -LiteralPath ..

    # Publish the app and create a zip file.
    Write-Host "Publishing application..."
    dotnet publish $pathToApp -c Release -o $pathToApp/publish

    Write-Host "Creating deployment package..."
    Compress-Archive -Path $pathToApp/publish/* -DestinationPath $pathToApp/publish.zip -Force

    # Log in to Azure using service principal credentials.
    Write-Host "Authenticating to Azure..."
    az login --service-principal --username $env:ARM_CLIENT_ID --password $env:ARM_CLIENT_SECRET --tenant $env:ARM_TENANT_ID | Out-Null

    # Deploy the Umbraco CMS to the app service.
    Write-Host "Deploying to App Service: $AppServiceName..."
    az webapp deployment source config-zip --src $pathToApp/publish.zip -n $AppServiceName -g $ResourceGroupName
}
finally {
    # Restore cwd and clean the build dir on every path (success and failure).
    Set-Location -LiteralPath $terraformCwd -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $absoluteBuildDir) {
        Write-Host "Cleaning up build artifacts..."
        Remove-Item -Recurse -Force -LiteralPath $absoluteBuildDir -ErrorAction SilentlyContinue
    }
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
        $responseBody = $response.Content | ConvertFrom-Json

        # Terminal-OK states: Completed, CompletedWithErrors, Skipped.
        if ($seederStatusCode -eq 200 -and $responseBody.Status -in @("Completed", "CompletedWithErrors", "Skipped")) {
            Write-Host ""
            if ($responseBody.Status -eq "Skipped") {
                Write-Host "Data seeder was disabled in scenario config - skipping wait." -ForegroundColor Green
            } else {
                $elapsedSeconds = [math]::Round($responseBody.ElapsedMs / 1000, 2)
                $verb = ($responseBody.Status -eq "CompletedWithErrors") ? "completed with errors" : "completed successfully"
                Write-Host "Data seeder $verb!" -ForegroundColor Green
                Write-Host "  Duration: $elapsedSeconds seconds"
                Write-Host "  Executed: $($responseBody.ExecutedCount)"
                Write-Host "  Failed: $($responseBody.FailedCount)"
            }
            $seederComplete = $true
            $seederSuccess = $true
        }
        elseif ($seederStatusCode -eq 503) {
            Write-Host ""
            Write-Host "ERROR: Seeder reported failure - $($responseBody.ErrorMessage)" -ForegroundColor Red
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
