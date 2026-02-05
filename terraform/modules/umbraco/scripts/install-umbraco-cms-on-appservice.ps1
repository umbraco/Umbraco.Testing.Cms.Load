[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]
    $rgName,
    [Parameter(Mandatory = $true)]
    [string]
    $appserviceName,
    [Parameter(Mandatory = $true)]
    [string]
    $appserviceHostname,
    [Parameter(Mandatory = $true)]
    [string]
    $umbracoVersion,
    [Parameter(Mandatory= $true)]
    [string]
    $client_id,
    [Parameter(Mandatory= $true)]
    [string]
    $client_secret,
    [Parameter(Mandatory= $true)]
    [string]
    $tenant_id
)

# Exit on error
$ErrorActionPreference = "Stop"

Write-Host "=============================================="
Write-Host "Deploying Umbraco $umbracoVersion"
Write-Host "App Service: $appserviceName"
Write-Host "Resource Group: $rgName"
Write-Host "=============================================="

# Remove dots from Umbraco version for creating folder
$updatedVersionName = $umbracoVersion.Replace('.','')

$pathToApp = "./NewUmbracoProject$updatedVersionName"
$nameToApp = "NewUmbracoProject$updatedVersionName"

# Create a new folder for Umbraco Template installation
mkdir $updatedVersionName

# Switch location to the new directory
Set-Location $updatedVersionName

# Add nuget package sources for Umbraco prereleases and nightly builds
dotnet nuget add source "https://www.myget.org/F/umbracoprereleases/api/v3/index.json" -n "Umbraco Prereleases" 2>$null
dotnet nuget add source "https://www.myget.org/F/umbraconightly/api/v3/index.json" -n "Umbraco Nightly" 2>$null

# Install Umbraco Template and create the project
Write-Host "Installing Umbraco.Templates::$umbracoVersion..."
dotnet new install Umbraco.Templates::$umbracoVersion
if ($LASTEXITCODE -ne 0) { throw "Failed to install Umbraco templates" }

Write-Host "Creating Umbraco project..."
dotnet new umbraco -n $nameToApp
if ($LASTEXITCODE -ne 0) { throw "Failed to create Umbraco project" }

cd $nameToApp

# Add performance test data seeder package
# This creates test content for load testing 
Write-Host "Adding PerformanceTestDataSeeder package..."
dotnet add package Umbraco.PerformanceTestDataSeeder
# WE ALSO NEED TO SPECIFY WHICH VERSION AND UPDATE APP SETTINGS
if ($LASTEXITCODE -ne 0) { throw "Failed to add PerformanceTestDataSeeder package" }

# Build the project
Write-Host "Building project..."
dotnet build -c Release
if ($LASTEXITCODE -ne 0) { throw "Failed to build project" }

cd ..

# Publish the app and create a zip file
dotnet publish $pathToApp -c Release -o $pathToApp/publish
Compress-Archive -Path $pathToApp/publish/* -DestinationPath $pathToApp/publish.zip

# Log in to Azure using service principal credentials
az login --service-principal --username $client_id --password $client_secret --tenant $tenant_id

# Deploy the Umbraco CMS to the app service
az webapp deployment source config-zip --src $pathToApp/publish.zip -n  $appserviceName -g $rgName

# Clean up the app folder
Remove-Item -Recurse -Force $pathToApp

# Return to the root folder of the Terraform project
Set-Location ..

# Clean up the Umbraco Template install folder
Remove-Item -Recurse -Force $updatedVersionName

# Ping the App Service to trigger the installation process
function Get-UrlStatusCode([string] $Url)
{
    try
    {
        (Invoke-WebRequest -Uri $Url -UseBasicParsing -DisableKeepAlive -TimeoutSec 120).StatusCode
    }
    catch [Net.WebException]
    {
        [int]$_.Exception.Response.StatusCode
    }
    catch
    {
        Write-Host "Error pinging URL: $_"
        return 0
    }
}

# Ensure hostname has https:// prefix
$pingUrl = $appserviceHostname
if (-not $pingUrl.StartsWith("http")) {
    $pingUrl = "https://$pingUrl"
}

Write-Host "Pinging $pingUrl to trigger Umbraco installation..."

# Retry logic for initial ping (Umbraco install can take time)
$maxRetries = 5
$retryCount = 0
$statusCode = 0

while ($retryCount -lt $maxRetries -and $statusCode -ne 200) {
    $retryCount++
    Write-Host "Attempt $retryCount of $maxRetries..."

    $statusCode = Get-UrlStatusCode $pingUrl
    Write-Host "StatusCode: $statusCode"

    if ($statusCode -ne 200 -and $retryCount -lt $maxRetries) {
        Write-Host "Waiting 30 seconds before retry..."
        Start-Sleep -Seconds 30
    }
}

if ($statusCode -eq 200) {
    Write-Host "Umbraco installation triggered successfully!"
} else {
    Write-Host "Warning: Could not verify Umbraco installation (status: $statusCode)"
    Write-Host "The site may still be installing. Continuing..."
}

# Stop the app service to save costs until tests run
Write-Host "Stopping App Service $appserviceName..."
az webapp stop -n $appserviceName -g $rgName

Write-Host "Deployment complete!"