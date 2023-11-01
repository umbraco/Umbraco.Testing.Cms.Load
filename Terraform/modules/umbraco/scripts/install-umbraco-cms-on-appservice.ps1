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

# Adds the starter kit Clean
dotnet add package clean

# Build the project to retrieve files from the Clean Starter Kit
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

# Ping the App Service to trigger the installation process
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

$statusCode = Get-UrlStatusCode $appserviceHostname
Write-Host "StatusCode is: $statusCode"

# Stop the app service
az webapp stop -n $appserviceName -g $rgName