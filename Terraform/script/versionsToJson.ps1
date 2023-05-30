[CmdletBinding()]
param (
    [Parameter]
    [AllowNull]
    $firstDotNetVersion,
    [Parameter]
    [AllowNull]
    $firstUmbracoVersion, 
    [Parameter]
    [AllowNull]
    $secondDotNetVersion,
    [Parameter]
    [AllowNull]
    $secondUmbracoVersion, 
    [Parameter]
    [AllowNull]
    $thirdDotNetVersion,
    [Parameter]
    [AllowNull]
    $thirdUmbracoVersion, 
    [Parameter]
    [AllowNull]
    $fourthDotNetVersion,
    [Parameter]
    [AllowNull]
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
    if ($Hashtables[$versions]["dotnet_version"] -and $Hashtables[$versions]["umbraco_version"]) {
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

Write-Host $JsonTest