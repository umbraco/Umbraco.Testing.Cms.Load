[CmdletBinding()]
param (
    [Parameter]
    [string]
    [AllowEmptyString()]
    $firstDotNetVersion,
    [Parameter]
    [string]
    [AllowEmptyString()]
    $firstUmbracoVersion, 
    [Parameter]
    [string]
    [AllowEmptyString()]
    $secondDotNetVersion,
    [Parameter]
    [string]
    [AllowEmptyString]
    $secondUmbracoVersion, 
    [Parameter]
    [string]
    [AllowEmptyString()]
    $thirdDotNetVersion,
    [Parameter]
    [string]
    [AllowEmptyString()]
    $thirdUmbracoVersion, 
    [Parameter]
    [string]
    [AllowEmptyString()]
    $fourthDotNetVersion,
    [Parameter]
    [string]
    [AllowEmptyString()]
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