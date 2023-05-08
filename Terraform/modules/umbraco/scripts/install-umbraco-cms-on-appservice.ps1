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
    #[Parameter(DontShow, Mandatory= $true)]
    [Parameter(Mandatory= $true)]
    [string]
    $client_id,
    #[Parameter(DontShow, Mandatory= $true)]
    [Parameter(Mandatory= $true)]
    [string]
    $client_secret,
    #[Parameter(DontShow, Mandatory= $true)]
    [Parameter(Mandatory= $true)]
    [string]
    $tenant_id
)

$pathToApp = "./NewUmbracoProject$umbracoVersion"
$nameToApp = "NewUmbracoProject$umbracoVersion"

# Creates a new folder for the Umbraco Template to be installed to
mkdir $umbracoVersion

# Switches location to the directory
Set-Location $umbracoVersion

# Adds the possibility to use prereleases of Umbraco
dotnet nuget add source "https://www.myget.org/F/umbracoprereleases/api/v3/index.json" -n "Umbraco Prereleases"

# Install Umbraco Template and create the project
dotnet new install Umbraco.Templates::$umbracoVersion
dotnet new umbraco -n $nameToApp

# Adds the starter kit Clean
dotnet add $nameToApp package clean

# Publish the app and zip it up
dotnet publish $pathToApp -c Release -o $pathToApp/publish
Compress-Archive -Path $pathToApp/publish/* -DestinationPath $pathToApp/publish.zip

# Logs in to azure with the username, password and tenant id we have recieved from our pipeline
az login --service-principal --username $client_id --password $client_secret --tenant $tenant_id

# Deploy the Umbraco CMS to the app service
az webapp deployment source config-zip --src $pathToApp/publish.zip -n  $appserviceName -g $rgName

# Clean up the app folder
# There should be no need to clean up the folders, since they will be deleted anyway
Remove-Item -Recurse -Force $pathToApp

# Goes back to the root folder of the terraform project
Set-Location ..

# Cleans up the Umbraco Template install folder
Remove-Item -Force $umbracoVersion

# # Ping the App service to trigger the installation process
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

# Stops the app service
az webapp stop -n $appserviceName -g $rgName