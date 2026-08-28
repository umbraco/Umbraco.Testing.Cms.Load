Describe 'resolve-run-config client workload validation' {
    It 'rejects client workload when scenario has no client/ project' {
        $tmp = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid()))
        New-Item -ItemType Directory -Path (Join-Path $tmp 'loadtests/scenarios/Bare') -Force | Out-Null
        $out = pwsh -NoProfile -File "$PSScriptRoot/../resolve-run-config.ps1" `
            -Profile standard -UmbracoVersion 17.0.0 -Scenario Bare `
            -RunStarter True -RunStandard False -RunPro False -RunEnterprise False `
            -PoolDtuOverride Auto -AppSkuOverride Auto -SeederPresetOverride Auto `
            -Workload client -WorkspaceRoot $tmp 2>&1
        $LASTEXITCODE | Should -Not -Be 0
        ($out -join "`n") | Should -Match 'client/'
    }
    It 'passes the client-specific check when scenario has a client/ project' {
        $tmp = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid()))
        New-Item -ItemType Directory -Path (Join-Path $tmp 'loadtests/scenarios/Default/client') -Force | Out-Null
        'export default {}' | Out-File (Join-Path $tmp 'loadtests/scenarios/Default/client/playwright.config.ts')
        # Validation should pass the client-specific check (it may still fail later in
        # prepare-test-cases if that helper isn't reachable in the temp workspace — we
        # only assert the CLIENT check itself didn't fire).
        $out = pwsh -NoProfile -File "$PSScriptRoot/../resolve-run-config.ps1" `
            -Profile standard -UmbracoVersion 17.0.0 -Scenario Default `
            -RunStarter True -RunStandard False -RunPro False -RunEnterprise False `
            -PoolDtuOverride Auto -AppSkuOverride Auto -SeederPresetOverride Auto `
            -Workload client -WorkspaceRoot $tmp 2>&1
        ($out -join "`n") | Should -Not -Match 'has no client/ project'
    }
}
