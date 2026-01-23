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

# Remove dots from Umbraco version for creating folder
$updatedVersionName = $umbracoVersion.Replace('.','')

$pathToApp = "./NewUmbracoProject$updatedVersionName"
$nameToApp = "NewUmbracoProject$updatedVersionName"

# Create a new folder for Umbraco Template installation
mkdir $updatedVersionName

# Switch location to the new directory
Set-Location $updatedVersionName

# Add nuget package sources for Umbraco prereleases and nightly builds
dotnet nuget add source "https://www.myget.org/F/umbracoprereleases/api/v3/index.json" -n "Umbraco Prereleases"
dotnet nuget add source "https://www.myget.org/F/umbraconightly/api/v3/index.json" -n "Umbraco Nightly"

# Install Umbraco Template and create the project
dotnet new install Umbraco.Templates::$umbracoVersion
dotnet new umbraco -n $nameToApp

cd $nameToApp

# We might need to do the same as before related to versioning 
# Add DummyDataSeeder package (supports Umbraco 13+)
if ($umbracoVersion -ge "13.0.0") {
    dotnet add package Umbraco.Community.DummyDataSeeder
}

# Build the project
dotnet build

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
Remove-Item -Force $updatedVersionName

# Helper function to get URL status code
function Get-UrlStatusCode([string] $Url)
{
    try
    {
        (Invoke-WebRequest -Uri $Url -UseBasicParsing -DisableKeepAlive).StatusCode
    }
    catch [Net.WebException]
    {
        [int]$_.Exception.Response.StatusCode
    }
}

# Trigger Umbraco startup
$statusCode = Get-UrlStatusCode "https://$appserviceHostname"
Write-Host "Initial StatusCode is: $statusCode"

# Wait for seeder to complete (max 60 minutes for large presets)
$seederStatusUrl = "https://$appserviceHostname/umbraco/api/seederstatus/status"
$maxAttempts = 360
$attempt = 0
$seederComplete = $false

Write-Host "Waiting for DummyDataSeeder to complete..."

while ($attempt -lt $maxAttempts -and -not $seederComplete) {
    Start-Sleep -Seconds 10
    $attempt++

    try {
        $response = Invoke-WebRequest -Uri $seederStatusUrl -UseBasicParsing
        $seederStatusCode = $response.StatusCode
        $responseBody = $response.Content | ConvertFrom-Json

        Write-Host "Attempt $attempt`: Seeder status: $($responseBody.Status)"

        if ($seederStatusCode -eq 200) {
            $elapsedSeconds = [math]::Round($responseBody.ElapsedMs / 1000, 2)
            Write-Host "DummyDataSeeder completed successfully!"
            Write-Host "Seeding took $elapsedSeconds seconds ($($responseBody.ElapsedMs) ms)"
            Write-Host "Executed: $($responseBody.ExecutedCount), Failed: $($responseBody.FailedCount)"
            $seederComplete = $true
        }
        elseif ($seederStatusCode -eq 503) {
            Write-Host "WARNING: Seeder reported failure - $($responseBody.ErrorMessage)"
            $seederComplete = $true
        }
        elseif ($responseBody.CurrentSeeder) {
            Write-Host "Currently running: $($responseBody.CurrentSeeder)"
        }
    }
    catch {
        Write-Host "Attempt $attempt`: Error checking seeder status: $_"
        if ($attempt -gt 6) {
            Write-Host "Seeder endpoint not responding - assuming complete"
            $seederComplete = $true
        }
    }
}

# Stop the app service
az webapp stop -n $appserviceName -g $rgName