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
    It 'rejects a mapped major whose seeder has not shipped' {
        $out = (& $run '16.0.0') -join "`n"
        $LASTEXITCODE | Should -Not -Be 0
        $out | Should -Match "hasn't shipped a build for major 16"
    }
}
