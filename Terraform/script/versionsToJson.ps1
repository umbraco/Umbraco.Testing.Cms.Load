[CmdletBinding()]
param (
    [Parameter()]
    [string]
    $firstDotNetVersion,
    [Parameter()]
    [string]
    $firstUmbracoVersion, 
    [Parameter()]
    [string]
    $secondDotNetVersion,
    [Parameter()]
    [string]
    $secondUmbracoVersion, 
    [Parameter()]
    [string]
    $thirdDotNetVersion,
    [Parameter()]
    [string]
    $thirdUmbracoVersion, 
    [Parameter()]
    [string]
    $fourthDotNetVersion,
    [Parameter()]
    [string]
    $fourthUmbracoVersion,

    [hashtable[]]
    $Hashtables
    )

    $Hashtables = @{"dotnet_version" = '\' +$firstDotNetVersion; "umbraco_version" = $firstUmbracoVersion}, @{"dotnet_version" = $secondDotNetVersion; "umbraco_version" = $secondUmbracoVersion}, @{"dotnet_version" = $thirdDotNetVersion; "umbraco_version" = $thirdUmbracoVersion}, @{"dotnet_version" = $fourthDotNetVersion; "umbraco_version" = $fourthUmbracoVersion}

    $Test = $Hashtables | ConvertTo-Json

    #Write-Host $Test

   # foreach ($entry in $Hashtables[2].GetEnumerator()) {
    #    Write-Host "    " $entry.Key = $entry.Value
    #}

    foreach ($testtt in $Hashtables){
        Write-Host "    " $testtt.Key = $testtt.Value

    }

    Write-Host $Hashtables.keys