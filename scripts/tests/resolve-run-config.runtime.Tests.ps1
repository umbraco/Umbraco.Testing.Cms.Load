Describe 'resolve-run-config Umbraco major -> .NET runtime map' {
    BeforeAll {
        # Minimal workspace: a Default scenario with a locustfile plus the real
        # seeder version map and tier catalog, so the whole validator (including
        # prepare-test-cases.ps1) exits cleanly.
        $script:ws = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid()))
        New-Item -ItemType Directory -Path (Join-Path $ws 'loadtests/scenarios/Default') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $ws 'scripts') -Force | Out-Null
        '' | Out-File (Join-Path $ws 'loadtests/scenarios/Default/locustfile.py')
        Copy-Item "$PSScriptRoot/../seeder-versions.json" (Join-Path $ws 'scripts/seeder-versions.json')
        Copy-Item "$PSScriptRoot/../../loadtests/tiers.json" (Join-Path $ws 'loadtests/tiers.json')
        # The real provider lock, so the blocked-major message's version lookup
        # (a regex over the lock file) is exercised rather than its fallback.
        New-Item -ItemType Directory -Path (Join-Path $ws 'Terraform') -Force | Out-Null
        Copy-Item "$PSScriptRoot/../../Terraform/.terraform.lock.hcl" (Join-Path $ws 'Terraform/.terraform.lock.hcl')
        Copy-Item "$PSScriptRoot/../prepare-test-cases.ps1" (Join-Path $ws 'scripts/prepare-test-cases.ps1')
        Copy-Item "$PSScriptRoot/../_helpers.ps1" (Join-Path $ws 'scripts/_helpers.ps1')
        $script:run = {
            param($Version)
            pwsh -NoProfile -File "$PSScriptRoot/../resolve-run-config.ps1" `
                -Profile standard -UmbracoVersion $Version -Scenario Default `
                -RunStarter True -RunStandard False -RunPro False -RunEnterprise False `
                -PoolDtuOverride Auto -AppSkuOverride Auto -SeederPresetOverride Auto `
                -Workload frontend -WorkspaceRoot $ws -SkipNuGetCheck 2>&1
        }
    }
    AfterAll {
        Remove-Item -LiteralPath $script:ws -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'resolves v19 to .NET 11 GA SDKs' {
        # Unblocked by the azurerm 5.15.0 lock bump (the provider accepts
        # 'v11.0' from that release).
        $out = (& $run '19.0.0-beta1') -join "`n"
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match 'major 19\) -> \.NET v11\.0 \(SDK 11\.x, preview SDKs: false\)'
        $out | Should -Match 'resolvedSdkIncludePreview;isOutput=true\]false'
    }
    It 'keeps v18 on .NET 10 GA SDKs' {
        $out = (& $run '18.0.0') -join "`n"
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match 'major 18\) -> \.NET v10\.0 \(SDK 10\.x, preview SDKs: false\)'
        $out | Should -Match 'resolvedSdkIncludePreview;isOutput=true\]false'
    }
    It 'rejects a major with no runtime mapping and lists what can run today' {
        # Derived from the seeder map the workspace carries, so adding a seeder
        # entry for a major that is also mapped (and not blocked) in
        # resolve-run-config.ps1 doesn't break this test. A seeder entry for an
        # unmapped major would, by design: the two must be added together.
        $seeder = Get-Content (Join-Path $ws 'scripts/seeder-versions.json') -Raw | ConvertFrom-Json -AsHashtable
        $majors = @($seeder.Keys | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ } | Sort-Object)
        $expected = ($majors | ForEach-Object { "v$_" }) -join ', '
        $unmapped = ($majors | Measure-Object -Maximum).Maximum + 1
        $out = (& $run "$unmapped.0.0") -join "`n"
        $LASTEXITCODE | Should -Not -Be 0
        $out | Should -Match "unsupported: no \.NET runtime is mapped for major $unmapped"
        $out | Should -Match ([regex]::Escape("can run $expected today"))
    }
    It 'keeps a single version on one SDK, with no second one' {
        $out = (& $run '17.0.0') -join "`n"
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match 'resolvedSdkVersion;isOutput=true\]10\.x'
        $out | Should -Match '(?m)resolvedSdkVersion2;isOutput=true\]\r?$'
        $out | Should -Match 'Validated 1 test case'
    }
    It 'turns two versions on two runtimes into one case each and a second SDK' {
        $out = (& $run '17.0.0, 19.0.0-beta1') -join "`n"
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match 'major 17\) -> \.NET v10\.0 \(SDK 10\.x'
        $out | Should -Match 'major 19\) -> \.NET v11\.0 \(SDK 11\.x'
        $out | Should -Match 'resolvedDotnetVersion;isOutput=true\]v10\.0'
        $out | Should -Match 'resolvedSdkVersion;isOutput=true\]10\.x'
        $out | Should -Match 'resolvedSdkVersion2;isOutput=true\]11\.x'
        # Each case carries its own runtime to Terraform and to the publish step.
        $tf = ([regex]::Match($out, 'variable=testCasesJson;isOutput=true\](.+)').Groups[1].Value).Replace('\"', '"') | ConvertFrom-Json
        $tf.'17.0.0__Starter__Default'.dotnet_version | Should -Be 'v10.0'
        $tf.'19.0.0-beta1__Starter__Default'.dotnet_version | Should -Be 'v11.0'
        $res = [regex]::Match($out, 'variable=resolvedTestCases;isOutput=true\](.+)').Groups[1].Value | ConvertFrom-Json
        $res.'17.0.0__Starter__Default'.dotnetVersion | Should -Be 'v10.0'
        $res.'19.0.0-beta1__Starter__Default'.dotnetVersion | Should -Be 'v11.0'
    }
    It 'needs no second SDK for two versions on the same runtime' {
        $out = (& $run '17.0.0,18.0.0') -join "`n"
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match '(?m)resolvedSdkVersion2;isOutput=true\]\r?$'
        $out | Should -Match '2 test case'
    }
    It 'rejects a repeated version, an empty entry and more than two SDKs' {
        (& $run '17.0.0,17.0.0') -join "`n" | Should -Match 'more than once'
        $LASTEXITCODE | Should -Not -Be 0
        (& $run '17.0.0,') -join "`n" | Should -Match 'empty entry'
        $LASTEXITCODE | Should -Not -Be 0
        (& $run '13.0.0,17.0.0,19.0.0') -join "`n" | Should -Match 'at most 2'
        $LASTEXITCODE | Should -Not -Be 0
    }
    It 'rejects a non-breaking space between versions at validation' {
        # The YAML replace() only drops plain spaces, so anything else must
        # fail here, not as a missing testCaseId after provisioning.
        $out = (& $run "17.0.0,$([char]0x00A0)19.0.0-beta1") -join "`n"
        $LASTEXITCODE | Should -Not -Be 0
        $out | Should -Match 'U\+00A0'
    }
    It 'rejects more than four versions' {
        $out = (& $run '13.0.0,13.0.1,13.0.2,13.0.3,13.0.4') -join "`n"
        $LASTEXITCODE | Should -Not -Be 0
        $out | Should -Match 'at most 4'
    }
    It 'only warns when the whole build is long, since each case is its own job' {
        $all = {
            param($Version, $Workload = 'frontend')
            pwsh -NoProfile -File "$PSScriptRoot/../resolve-run-config.ps1" `
                -Profile standard -UmbracoVersion $Version -Scenario Default `
                -RunStarter True -RunStandard True -RunPro True -RunEnterprise True `
                -PoolDtuOverride Auto -AppSkuOverride Auto -SeederPresetOverride Auto `
                -Workload $Workload -WorkspaceRoot $ws -SkipNuGetCheck 2>&1
        }
        # 4 versions x 4 tiers x ~23 min frontend standard = ~368 min.
        $out = (& $all '13.0.0,13.0.1,13.0.2,13.0.3') -join "`n"
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match 'about 368 minutes of load tests'
        # 2 x 4 x 23 = 184 min fits.
        $out = (& $all '13.0.0,17.0.0') -join "`n"
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match '8 case\(s\), about 184 min'
    }

    It 'rejects a mapped major whose seeder has not shipped' {
        $out = (& $run '16.0.0') -join "`n"
        $LASTEXITCODE | Should -Not -Be 0
        $out | Should -Match "hasn't shipped a build for major 16"
    }
}
