[CmdletBinding()]
param (
    [Parameter()]
    [string]
    $umbracoVersion

)

$updatedVersion = $umbracoVersion.Replace('.','')

$nameToApp = "v12Test"

if ($umbracoVersion.StartsWith("12")){
    Write-Host "It works"

    dotnet remove $nameToApp package Umbraco.CMS

    dotnet add $nameToApp package Umbraco.Cms.Targets -v $umbracoVersion
    dotnet add $nameToApp package Umbraco.Cms.Persistence.SqlServer -v $umbracoVersion
    dotnet add $nameToApp package Umbraco.Cms.Persistence.Sqlite -v $umbracoVersion
    dotnet add $nameToApp package Umbraco.Cms.Imaging.ImageSharp2 -v $umbracoVersion
}

Write-Host $updatedVersion
