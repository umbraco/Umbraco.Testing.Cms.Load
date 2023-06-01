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

$Hashtables = 
@{"dotnet_version"    = $firstDotNetVersion; 
    "umbraco_version" = $firstUmbracoVersion
}, 
@{"dotnet_version"    = $secondDotNetVersion;
    "umbraco_version" = $secondUmbracoVersion
}, 
@{"dotnet_version"    = $thirdDotNetVersion; 
    "umbraco_version" = $thirdUmbracoVersion
}, 
@{"dotnet_version"    = $fourthDotNetVersion; 
    "umbraco_version" = $fourthUmbracoVersion
}

$JsonTest

for ($versions = 0; $versions -lt $Hashtables.count; $versions++) {
    if ($Hashtables[$versions]["dotnet_version"] -ne "null" -and $Hashtables[$versions]["umbraco_version"] -ne "null") {
        $replaceSpecialChars = $Hashtables[$versions]["umbraco_version"].Replace('.','_')
        
        if ($JsonTest) {
            $JsonTest += ',"version' + $replaceSpecialChars + '" :{"dotnet_version":\"' + $Hashtables[$versions]["dotnet_version"] + '\","umbraco_version":\"' + $Hashtables[$versions]["umbraco_version"] + '\"}'
        }
        elseif (!$JsonTest) {
            $JsonTest += '{"version' + $replaceSpecialChars + '" :{"dotnet_version":\"' + $Hashtables[$versions]["dotnet_version"] + '\","umbraco_version":\"' + $Hashtables[$versions]["umbraco_version"] + '\"}'
        }
    }
}

if ($JsonTest) {
    $JsonTest += '}'
}

Write-Output "$JsonTest"

