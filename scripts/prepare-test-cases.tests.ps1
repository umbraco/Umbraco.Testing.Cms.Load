# Pester tests for prepare-test-cases.ps1.
#
# Run locally:
#   Invoke-Pester -Path ./scripts/prepare-test-cases.tests.ps1
#
# Pester 5.x is preinstalled on pwsh 7+ and Microsoft-hosted ubuntu agents.

BeforeAll {
    $script:scriptPath = Join-Path $PSScriptRoot 'prepare-test-cases.ps1'

    # Build a fresh workspace for each test run (TestDrive is auto-cleaned).
    $script:workspace = Join-Path $TestDrive 'ws'

    $tiersPath = Join-Path $script:workspace 'loadtests/tiers.json'
    New-Item -ItemType Directory -Path (Split-Path $tiersPath) -Force | Out-Null
    @{
        tiers = [ordered]@{
            Starter  = @{ app_sku = "P0v4"; sql_sku = "S0"; sql_max_size_gb = 5 }
            Standard = @{ app_sku = "P1v3"; sql_sku = "S1"; sql_max_size_gb = 10 }
            Pro      = @{ app_sku = "P3v3"; sql_sku = "S2"; sql_max_size_gb = 20 }
        }
    } | ConvertTo-Json -Depth 5 | Set-Content $tiersPath

    # Default scenario: empty overlay, no scenario.yaml.
    $defaultDir = Join-Path $script:workspace 'loadtests/scenarios/Default/AdditionalSetup'
    New-Item -ItemType Directory -Path $defaultDir -Force | Out-Null
    '{}' | Set-Content (Join-Path $defaultDir 'appsettings.json')

    # Rich scenario: nested overlay + scenario.yaml override.
    $richDir = Join-Path $script:workspace 'loadtests/scenarios/Rich/AdditionalSetup'
    New-Item -ItemType Directory -Path $richDir -Force | Out-Null
    @'
{
  "Umbraco": { "CMS": { "Content": { "AllowEditInvariantFromNonDefault": false } } },
  "Items": ["a", "b"]
}
'@ | Set-Content (Join-Path $richDir 'appsettings.json')
    @'
description: "Rich scenario for testing"
loadProfile:
  users: 250
  duration: 600
'@ | Set-Content (Join-Path (Split-Path $richDir) 'scenario.yaml')

    function script:Invoke-Validator {
        param (
            [Parameter(Mandatory)] [string] $Json,
            [int] $Users = 100,
            [int] $Spawn = 10,
            [int] $Duration = 300
        )
        $env:TEST_CASES_JSON = $Json
        try {
            $output = & $script:scriptPath `
                -UserAmount $Users -SpawnRate $Spawn -TestDuration $Duration `
                -WorkspaceRoot $script:workspace 2>&1
            return @{
                Output = $output
                ExitCode = $LASTEXITCODE
            }
        } finally {
            Remove-Item Env:TEST_CASES_JSON -ErrorAction SilentlyContinue
        }
    }

    function script:Get-OutputVariable {
        param ([Parameter(Mandatory)] $InvokerResult, [Parameter(Mandatory)] [string] $VariableName)
        $line = $InvokerResult.Output | Where-Object {
            $_ -match "##vso\[task\.setvariable variable=$VariableName"
        } | Select-Object -First 1
        if (-not $line) { return $null }
        # Extract the value after the closing ]
        return ($line -replace ".*]", "")
    }
}

Describe "prepare-test-cases.ps1" {

    Context "Input validation" {

        It "Fails on empty array" {
            { Invoke-Validator '[]' } | Should -Throw "*testCases is empty*"
        }

        It "Fails on missing required field" {
            { Invoke-Validator '[{"umbraco":"17.0.0","dotnet":"v10.0","tiers":["Standard"]}]' } |
                Should -Throw "*missing required field 'scenario'*"
        }

        It "Fails on missing tiers field" {
            { Invoke-Validator '[{"umbraco":"17.0.0","dotnet":"v10.0","scenario":"Default"}]' } |
                Should -Throw "*missing required field 'tiers'*"
        }

        It "Fails on empty tiers array" {
            { Invoke-Validator '[{"umbraco":"17.0.0","dotnet":"v10.0","scenario":"Default","tiers":[]}]' } |
                Should -Throw "*'tiers' array is empty*"
        }

        It "Fails on Umbraco major < 17" {
            { Invoke-Validator '[{"umbraco":"15.1.0","dotnet":"v9.0","scenario":"Default","tiers":["Standard"]}]' } |
                Should -Throw "*unsupported (this pipeline targets v17+*"
        }

        It "Fails on unknown tier" {
            { Invoke-Validator '[{"umbraco":"17.0.0","dotnet":"v10.0","scenario":"Default","tiers":["Bogus"]}]' } |
                Should -Throw "*tier 'Bogus' is not in tiers.json*"
        }

        It "Fails on missing scenario folder" {
            { Invoke-Validator '[{"umbraco":"17.0.0","dotnet":"v10.0","scenario":"Missing","tiers":["Standard"]}]' } |
                Should -Throw "*scenario folder not found*"
        }

        It "Fails on too-long scenario name" {
            { Invoke-Validator '[{"umbraco":"17.0.0","dotnet":"v10.0","scenario":"ThisNameIsTooLong","tiers":["Standard"]}]' } |
                Should -Throw "*max 15*"
        }

        It "Fails on invalid scenario name charset" {
            { Invoke-Validator '[{"umbraco":"17.0.0","dotnet":"v10.0","scenario":"Has_Underscore","tiers":["Standard"]}]' } |
                Should -Throw "*alphanumeric + hyphens*"
        }

        It "Fails on duplicate testCaseId after expansion" {
            $json = '[{"umbraco":"17.0.0","dotnet":"v10.0","scenario":"Default","tiers":["Standard","Standard"]}]'
            { Invoke-Validator $json } | Should -Throw "*duplicate testCaseId*"
        }

        It "Fails on out-of-range userAmount" {
            { Invoke-Validator '[{"umbraco":"17.0.0","dotnet":"v10.0","scenario":"Default","tiers":["Standard"]}]' -Users 5000 } |
                Should -Throw "*userAmount '5000' out of range*"
        }

        It "Fails on out-of-range spawnRate" {
            { Invoke-Validator '[{"umbraco":"17.0.0","dotnet":"v10.0","scenario":"Default","tiers":["Standard"]}]' -Spawn 500 } |
                Should -Throw "*spawnRate '500' out of range*"
        }

        It "Fails on out-of-range testDuration" {
            { Invoke-Validator '[{"umbraco":"17.0.0","dotnet":"v10.0","scenario":"Default","tiers":["Standard"]}]' -Duration 10 } |
                Should -Throw "*testDuration '10' out of range*"
        }
    }

    Context "Output shape" {
        # Catch refactors that drop fields the terraform variable schema relies on.
        # If any of these break, terraform plan would fail with a cryptic missing-
        # attribute error - the test should fail first with a clearer message.

        It "testCasesJson entries carry every field terraform needs" {
            $r = Invoke-Validator '[{"umbraco":"17.0.0","dotnet":"v10.0","scenario":"Default","tiers":["Standard"]}]'
            $tfJson = (Get-OutputVariable $r 'testCasesJson') -replace '\\"', '"'
            $obj = $tfJson | ConvertFrom-Json
            $entry = $obj.'17.0.0__Standard__Default'
            $entry.PSObject.Properties.Name | Should -Contain 'dotnet_version'
            $entry.PSObject.Properties.Name | Should -Contain 'umbraco_version'
            $entry.PSObject.Properties.Name | Should -Contain 'tier'
            $entry.PSObject.Properties.Name | Should -Contain 'scenario'
            $entry.PSObject.Properties.Name | Should -Contain 'app_settings_overlay'
            $entry.dotnet_version  | Should -Be 'v10.0'
            $entry.umbraco_version | Should -Be '17.0.0'
            $entry.tier            | Should -Be 'Standard'
            $entry.scenario        | Should -Be 'Default'
        }

        It "resolvedTestCases entries carry every field the load-test job hydrates" {
            $r = Invoke-Validator '[{"umbraco":"17.0.0","dotnet":"v10.0","scenario":"Default","tiers":["Standard"]}]'
            $obj = (Get-OutputVariable $r 'resolvedTestCases') | ConvertFrom-Json
            $entry = $obj.'17.0.0__Standard__Default'
            $entry.PSObject.Properties.Name | Should -Contain 'userAmount'
            $entry.PSObject.Properties.Name | Should -Contain 'spawnRate'
            $entry.PSObject.Properties.Name | Should -Contain 'testDuration'
            $entry.PSObject.Properties.Name | Should -Contain 'previousTestCaseId'
            $entry.PSObject.Properties.Name | Should -Contain 'label'
        }
    }

    Context "Tier expansion" {

        It "Expands one entry x N tiers into N test cases" {
            $r = Invoke-Validator '[{"umbraco":"17.0.0","dotnet":"v10.0","scenario":"Default","tiers":["Starter","Standard","Pro"]}]'
            $tfJson = Get-OutputVariable $r 'testCasesJson'
            # Unescape \" before parsing
            $obj = ($tfJson -replace '\\"', '"') | ConvertFrom-Json
            $obj.PSObject.Properties.Name | Should -HaveCount 3
            $obj.PSObject.Properties.Name | Should -Contain '17.0.0__Starter__Default'
            $obj.PSObject.Properties.Name | Should -Contain '17.0.0__Standard__Default'
            $obj.PSObject.Properties.Name | Should -Contain '17.0.0__Pro__Default'
        }

        It "Chains previousTestCaseId in tier order" {
            $r = Invoke-Validator '[{"umbraco":"17.0.0","dotnet":"v10.0","scenario":"Default","tiers":["Starter","Standard","Pro"]}]'
            $resJson = Get-OutputVariable $r 'resolvedTestCases'
            $obj = $resJson | ConvertFrom-Json
            $obj.'17.0.0__Starter__Default'.previousTestCaseId  | Should -Be ''
            $obj.'17.0.0__Standard__Default'.previousTestCaseId | Should -Be '17.0.0__Starter__Default'
            $obj.'17.0.0__Pro__Default'.previousTestCaseId      | Should -Be '17.0.0__Standard__Default'
        }
    }

    Context "Appsettings overlay flattening" {

        It "Empty {} produces empty overlay" {
            $r = Invoke-Validator '[{"umbraco":"17.0.0","dotnet":"v10.0","scenario":"Default","tiers":["Standard"]}]'
            $tfJson = (Get-OutputVariable $r 'testCasesJson') -replace '\\"', '"'
            $obj = $tfJson | ConvertFrom-Json
            $overlay = $obj.'17.0.0__Standard__Default'.app_settings_overlay
            ($overlay.PSObject.Properties.Name | Measure-Object).Count | Should -Be 0
        }

        It "Flattens nested objects with __ separators and stringifies booleans" {
            $r = Invoke-Validator '[{"umbraco":"17.0.0","dotnet":"v10.0","scenario":"Rich","tiers":["Standard"]}]'
            $tfJson = (Get-OutputVariable $r 'testCasesJson') -replace '\\"', '"'
            $obj = $tfJson | ConvertFrom-Json
            $overlay = $obj.'17.0.0__Standard__Rich'.app_settings_overlay
            $overlay.'Umbraco__CMS__Content__AllowEditInvariantFromNonDefault' | Should -Be 'false'
        }

        It "Flattens arrays as Section__0__Key" {
            $r = Invoke-Validator '[{"umbraco":"17.0.0","dotnet":"v10.0","scenario":"Rich","tiers":["Standard"]}]'
            $tfJson = (Get-OutputVariable $r 'testCasesJson') -replace '\\"', '"'
            $obj = $tfJson | ConvertFrom-Json
            $overlay = $obj.'17.0.0__Standard__Rich'.app_settings_overlay
            $overlay.'Items__0' | Should -Be 'a'
            $overlay.'Items__1' | Should -Be 'b'
        }
    }

    Context "Load profile resolution" {

        It "Uses pipeline defaults when scenario.yaml is absent" {
            $r = Invoke-Validator '[{"umbraco":"17.0.0","dotnet":"v10.0","scenario":"Default","tiers":["Standard"]}]' -Users 77 -Spawn 7 -Duration 77
            $obj = (Get-OutputVariable $r 'resolvedTestCases') | ConvertFrom-Json
            $entry = $obj.'17.0.0__Standard__Default'
            $entry.userAmount   | Should -Be 77
            $entry.spawnRate    | Should -Be 7
            $entry.testDuration | Should -Be 77
        }

        It "Applies scenario.yaml loadProfile overrides over pipeline defaults" {
            # Rich scenario.yaml sets users=250, duration=600; spawnRate is left to pipeline default.
            $r = Invoke-Validator '[{"umbraco":"17.0.0","dotnet":"v10.0","scenario":"Rich","tiers":["Standard"]}]' -Users 100 -Spawn 10 -Duration 300
            $obj = (Get-OutputVariable $r 'resolvedTestCases') | ConvertFrom-Json
            $entry = $obj.'17.0.0__Standard__Rich'
            $entry.userAmount   | Should -Be 250   # from scenario.yaml
            $entry.spawnRate    | Should -Be 10    # pipeline default (not overridden)
            $entry.testDuration | Should -Be 600   # from scenario.yaml
        }
    }
}
