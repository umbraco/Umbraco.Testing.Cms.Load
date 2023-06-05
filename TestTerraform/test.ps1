[CmdletBinding()]
param (
    [Parameter()]
    [string]
    $umbracoVersion

)


$updatedVersion = $umbracoVersion.Replace('.','')


Write-Host $updatedVersion
