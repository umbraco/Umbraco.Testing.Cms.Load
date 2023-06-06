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

# On version 9 you can't have a namespace with '.' so we remove them from the name.
$updatedVersionName = $umbracoVersion.Replace('.','')

$pathToApp = "./NewUmbracoProject$updatedVersionName"
$nameToApp = "NewUmbracoProject$updatedVersionName"

# Creates a new folder for the Umbraco Template to be installed to
mkdir $updatedVersionName

# Switches location to the directory
Set-Location $updatedVersionName

# Adds the possibility to use prereleases of Umbraco
dotnet nuget add source "https://www.myget.org/F/umbracoprereleases/api/v3/index.json" -n "Umbraco Prereleases"

# Install Umbraco Template and create the project
dotnet new install Umbraco.Templates::$umbracoVersion
dotnet new umbraco -n $nameToApp

# Adds the starter kit Clean
dotnet add $nameToApp package clean

# If we are using V12 we need to use ImageSharp2 instead of ImageSharp3
if ($umbracoVersion.StartsWith("12")){
    dotnet remove $nameToApp package Umbraco.CMS
    
    dotnet add $nameToApp package Umbraco.Cms.Targets -v $umbracoVersion
    dotnet add $nameToApp package Umbraco.Cms.Persistence.SqlServer -v $umbracoVersion
    dotnet add $nameToApp package Umbraco.Cms.Persistence.Sqlite -v $umbracoVersion
    dotnet add $nameToApp package Umbraco.Cms.Imaging.ImageSharp2 -v $umbracoVersion
}
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
Remove-Item -Force $updatedVersionName

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