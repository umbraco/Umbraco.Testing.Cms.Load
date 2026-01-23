[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$rgName,

    [Parameter(Mandatory = $true)]
    [string]$appserviceName,

    [Parameter(Mandatory = $true)]
    [string]$appserviceHostname,

    [Parameter(Mandatory = $true)]
    [string]$umbracoVersion,

    [Parameter(Mandatory = $true)]
    [string]$client_id,

    [Parameter(Mandatory = $true)]
    [string]$client_secret,

    [Parameter(Mandatory = $true)]
    [string]$tenant_id
)

$ErrorActionPreference = "Stop"

# Remove dots from Umbraco version for creating folder
$updatedVersionName = $umbracoVersion.Replace('.', '')
$pathToApp = "./NewUmbracoProject$updatedVersionName"
$nameToApp = "NewUmbracoProject$updatedVersionName"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Deploying Umbraco $umbracoVersion" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Create a new folder for Umbraco Template installation
Write-Host "Creating project directory: $updatedVersionName"
New-Item -ItemType Directory -Path $updatedVersionName -Force | Out-Null

# Switch location to the new directory
Set-Location $updatedVersionName

# Add NuGet package sources for Umbraco prereleases and nightly builds
Write-Host "Adding NuGet sources for prereleases and nightly builds..."
dotnet nuget add source "https://www.myget.org/F/umbracoprereleases/api/v3/index.json" -n "Umbraco Prereleases" 2>$null
dotnet nuget add source "https://www.myget.org/F/umbraconightly/api/v3/index.json" -n "Umbraco Nightly" 2>$null

# Install Umbraco Template and create the project
Write-Host "Installing Umbraco.Templates::$umbracoVersion..."
dotnet new install Umbraco.Templates::$umbracoVersion

Write-Host "Creating new Umbraco project: $nameToApp..."
dotnet new umbraco -n $nameToApp

Set-Location $nameToApp

# Add DummyDataSeeder package (supports Umbraco 13+)
$majorVersion = [int]($umbracoVersion -split '\.')[0]
if ($majorVersion -ge 13) {
    Write-Host "Adding DummyDataSeeder package for Umbraco $majorVersion..."
    dotnet add package Umbraco.Community.DummyDataSeeder --version "$majorVersion.*"
}
else {
    Write-Host "Skipping DummyDataSeeder (requires Umbraco 13+, found $majorVersion)"
}

# Build the project
Write-Host "Building project..."
dotnet build --configuration Release

Set-Location ..

# Publish the app and create a zip file
Write-Host "Publishing application..."
dotnet publish $pathToApp -c Release -o $pathToApp/publish

Write-Host "Creating deployment package..."
Compress-Archive -Path $pathToApp/publish/* -DestinationPath $pathToApp/publish.zip -Force

# Log in to Azure using service principal credentials
Write-Host "Authenticating to Azure..."
az login --service-principal --username $client_id --password $client_secret --tenant $tenant_id | Out-Null

# Deploy the Umbraco CMS to the app service
Write-Host "Deploying to App Service: $appserviceName..."
az webapp deployment source config-zip --src $pathToApp/publish.zip -n $appserviceName -g $rgName

# Clean up the app folder
Write-Host "Cleaning up build artifacts..."
Remove-Item -Recurse -Force $pathToApp

# Return to the root folder of the Terraform project
Set-Location ..

# Clean up the Umbraco Template install folder
Remove-Item -Recurse -Force $updatedVersionName

# Helper function to get URL status code
function Get-UrlStatusCode([string]$Url) {
    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -DisableKeepAlive -TimeoutSec 30
        return $response.StatusCode
    }
    catch [System.Net.WebException] {
        if ($_.Exception.Response) {
            return [int]$_.Exception.Response.StatusCode
        }
        return 0
    }
    catch {
        return 0
    }
}

# Trigger Umbraco startup
Write-Host "Triggering Umbraco startup..."
$statusCode = Get-UrlStatusCode "https://$appserviceHostname"
Write-Host "Initial status code: $statusCode"

# Wait for seeder to complete (max 60 minutes for large presets)
$seederStatusUrl = "https://$appserviceHostname/umbraco/api/seederstatus/status"
$maxAttempts = 360
$attempt = 0
$seederComplete = $false

Write-Host ""
Write-Host "Waiting for DummyDataSeeder to complete..." -ForegroundColor Yellow

while ($attempt -lt $maxAttempts -and -not $seederComplete) {
    Start-Sleep -Seconds 10
    $attempt++

    try {
        $response = Invoke-WebRequest -Uri $seederStatusUrl -UseBasicParsing -TimeoutSec 30
        $seederStatusCode = $response.StatusCode
        $responseBody = $response.Content | ConvertFrom-Json

        if ($seederStatusCode -eq 200 -and $responseBody.Status -eq "Completed") {
            $elapsedSeconds = [math]::Round($responseBody.ElapsedMs / 1000, 2)
            Write-Host ""
            Write-Host "DummyDataSeeder completed successfully!" -ForegroundColor Green
            Write-Host "  Duration: $elapsedSeconds seconds"
            Write-Host "  Executed: $($responseBody.ExecutedCount)"
            Write-Host "  Failed: $($responseBody.FailedCount)"
            $seederComplete = $true
        }
        elseif ($seederStatusCode -eq 503) {
            Write-Host ""
            Write-Host "WARNING: Seeder reported failure - $($responseBody.ErrorMessage)" -ForegroundColor Red
            $seederComplete = $true
        }
        else {
            $status = if ($responseBody.CurrentSeeder) { $responseBody.CurrentSeeder } else { $responseBody.Status }
            Write-Host "  [$attempt/$maxAttempts] Status: $status"
        }
    }
    catch {
        Write-Host "  [$attempt/$maxAttempts] Waiting for seeder endpoint..."
        if ($attempt -gt 12) {
            Write-Host ""
            Write-Host "Seeder endpoint not responding after 2 minutes - assuming complete" -ForegroundColor Yellow
            $seederComplete = $true
        }
    }
}

if (-not $seederComplete) {
    Write-Host ""
    Write-Host "WARNING: Seeder did not complete within timeout period" -ForegroundColor Red
}

# Stop the app service to save resources until load test
Write-Host ""
Write-Host "Stopping App Service until load test..." -ForegroundColor Cyan
az webapp stop -n $appserviceName -g $rgName

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "Deployment complete: $umbracoVersion" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
