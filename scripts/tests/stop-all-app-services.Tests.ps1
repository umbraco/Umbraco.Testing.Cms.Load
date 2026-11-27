Describe 'stop-all-app-services retries a failed stop' {
    BeforeAll {
        $script:scriptPath = "$PSScriptRoot/../stop-all-app-services.ps1"
        $env:TEST_CASE_OUTPUTS = '{"a__Starter__X":{"app_service_name":"app-a"},"b__Starter__X":{"app_service_name":"app-b"}}'
        # Stand-in for the Azure CLI: fails the first $failFirst stops of each
        # app, records every call. A function wins over the native az here.
        function global:az {
            $name = $args[$args.IndexOf('-n') + 1]
            $global:azCalls += , $name
            $count = @($global:azCalls | Where-Object { $_ -eq $name }).Count
            $global:LASTEXITCODE = if ($count -le $global:failFirst) { 1 } else { 0 }
        }
    }
    AfterAll {
        Remove-Item function:global:az -ErrorAction SilentlyContinue
        Remove-Item env:TEST_CASE_OUTPUTS -ErrorAction SilentlyContinue
    }
    BeforeEach { $global:azCalls = @() }

    It 'tries again after a transient failure and stops once it succeeds' {
        $global:failFirst = 1
        & $scriptPath -ResourceGroupName rg -RetryDelaySeconds 0 3>$null
        @($global:azCalls | Where-Object { $_ -eq 'app-a' }).Count | Should -Be 2
        @($global:azCalls | Where-Object { $_ -eq 'app-b' }).Count | Should -Be 2
    }
    It 'gives up after the set number of attempts and carries on with the next app' {
        $global:failFirst = 99
        $warnings = & $scriptPath -ResourceGroupName rg -RetryDelaySeconds 0 -Attempts 3 3>&1 |
            Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
        @($global:azCalls | Where-Object { $_ -eq 'app-a' }).Count | Should -Be 3
        @($global:azCalls | Where-Object { $_ -eq 'app-b' }).Count | Should -Be 3
        @($warnings | Where-Object { "$_" -match 'after 3 attempts' }).Count | Should -Be 2
    }
    It 'leaves the current case alone' {
        $global:failFirst = 0
        & $scriptPath -ResourceGroupName rg -ExceptAppService app-a -RetryDelaySeconds 0
        $global:azCalls | Should -Be @('app-b')
    }
}

Describe 'stop-all-app-services and the plan of the case about to start' {
    BeforeAll {
        $script:scriptPath = "$PSScriptRoot/../stop-all-app-services.ps1"
        # a and b share the Starter plan; c is on the Standard plan.
        $env:TEST_CASE_OUTPUTS = (@{
                'a__Starter__X'  = @{ app_service_name = 'app-a'; app_service_plan_id = '/plans/starter' }
                'b__Starter__X'  = @{ app_service_name = 'app-b'; app_service_plan_id = '/plans/starter' }
                'c__Standard__X' = @{ app_service_name = 'app-c'; app_service_plan_id = '/plans/standard' }
            } | ConvertTo-Json -Compress)
        # Stand-in for the Azure CLI: every stop of an app in $global:failing fails.
        function global:az {
            $name = $args[$args.IndexOf('-n') + 1]
            $global:azCalls += , $name
            $global:LASTEXITCODE = if ($global:failing -contains $name) { 1 } else { 0 }
        }
    }
    AfterAll {
        Remove-Item function:global:az -ErrorAction SilentlyContinue
        Remove-Item env:TEST_CASE_OUTPUTS -ErrorAction SilentlyContinue
    }
    BeforeEach { $global:azCalls = @() }

    It 'fails when a sibling on the same plan will not stop, after trying every app' {
        $global:failing = @('app-b')
        $out = (& $scriptPath -ResourceGroupName rg -ExceptAppService app-a -RetryDelaySeconds 0 -Attempts 2 *>&1) -join "`n"
        $LASTEXITCODE | Should -Be 1
        $out | Should -Match 'Could not stop app-b'
        $global:azCalls | Should -Contain 'app-c'
    }
    It 'only warns when the app that will not stop is on another plan' {
        $global:failing = @('app-c')
        & $scriptPath -ResourceGroupName rg -ExceptAppService app-a -RetryDelaySeconds 0 -Attempts 2 3>$null 6>$null
        $LASTEXITCODE | Should -Be 0
    }
    It 'only warns in the end-of-run sweep, even when the last app fails' {
        $global:failing = @('app-a', 'app-b', 'app-c')
        & $scriptPath -ResourceGroupName rg -RetryDelaySeconds 0 -Attempts 1 3>$null 6>$null
        $LASTEXITCODE | Should -Be 0
    }
}
