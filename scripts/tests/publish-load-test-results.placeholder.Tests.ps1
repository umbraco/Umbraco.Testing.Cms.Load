# publish-load-test-results.ps1 for a tier that failed before its load test
# ran, with `az` stubbed. templates/load-test-job.yml clears a tier's state
# before it starts, so such a tier reaches the publish step with no results
# dir, no window start and no App Service resource id - and must still publish
# its placeholder row, which check-regression.ps1 uses to tell "this run
# attempted the tier and it failed" from "this run never touched the tier".
Describe 'publish-load-test-results: tier that failed before its load test' {
    BeforeAll {
        $script:work = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid()))
        # The publish below has no Log Analytics target on purpose. Inside the
        # pipeline (the validate stage runs these tests) TF_BUILD would turn
        # that into a build warning about failed monitoring; hide it here.
        $script:tfBuild = $env:TF_BUILD
        $env:TF_BUILD = $null
        $global:PublishTestUploaded = Join-Path $work 'uploaded.ndjson'
        $global:PublishTestAzCalls  = [System.Collections.Generic.List[string]]::new()

        function global:az {
            $a = $args -join ' '
            $global:PublishTestAzCalls.Add($a)
            if ($a -like 'storage account keys list*') { return 'fake-key' }
            if ($a -like 'storage blob upload *') {
                Copy-Item -LiteralPath $args[[array]::IndexOf($args, '--file') + 1] -Destination $global:PublishTestUploaded -Force
                return
            }
            throw "unexpected az call in test: $a"
        }

        $script:publish = {
            & "$PSScriptRoot/../publish-load-test-results.ps1" `
                -ResultsDir (Join-Path $work 'no-such-dir') `
                -HistoryResourceGroup rg -StorageAccountName sa -ContainerName c `
                -BuildId 4242 -Commit abcdef1234 -Branch test -RunStartedAt '2026-11-23 10:00:00+00:00' `
                -UmbracoVersion 18.3.2 -DotNetVersion v10.0 -AppServiceSku P0v3 -PoolDtuMax 20 -SeederPreset Medium `
                -Tier Standard -Scenario Default -UserCount 50 -SpawnRate 10 -DurationSeconds 300 -SkipWarmup False `
                -TestCaseId '18.3.2__Standard__Default' -RampTimeSeconds 0 -LoadProfile standard `
                -LoadTestStartTime '' -LoadTestEndTime '2026-11-23T10:20:00.0000000Z' -AppServiceResourceId '' `
                -AppServicePlanResourceId '/subscriptions/x/plan' -SqlDatabaseResourceId '/subscriptions/x/db' `
                -LogAnalyticsDceUri '' -LogAnalyticsDcrImmutableId '' -LogAnalyticsStreamName '' -LogAnalyticsSeriesStreamName '' `
                6>$null 3>$null
        }
        # Once, here: every It below asserts on what this one publish left
        # behind, so each still passes when run on its own.
        $script:publishError = $null
        try { & $publish } catch { $script:publishError = $_ }
    }
    AfterAll {
        $env:TF_BUILD = $script:tfBuild
        Remove-Item -Path Function:\az -ErrorAction SilentlyContinue
        Remove-Variable -Name PublishTestUploaded, PublishTestAzCalls -Scope Global -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:work -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'publishes one no_results_dir placeholder row instead of throwing on the empty inputs' {
        $script:publishError | Should -BeNullOrEmpty
        $global:PublishTestUploaded | Should -Exist
        $rows = @(Get-Content -LiteralPath $global:PublishTestUploaded | ForEach-Object { $_ | ConvertFrom-Json })
        $rows.Count | Should -Be 1
        $rows[0].parse_status    | Should -Be 'no_results_dir'
        $rows[0].infra_tier      | Should -Be 'Standard'
        $rows[0].umbraco_version | Should -Be '18.3.2'
        # No metrics: a placeholder must never look like a measurement.
        $rows[0].scenario_name   | Should -BeNullOrEmpty
        $rows[0].p95_ms          | Should -BeNullOrEmpty
    }

    It 'records the seeder package build from seeder-versions.json' {
        $expected = (Get-Content -LiteralPath "$PSScriptRoot/../seeder-versions.json" -Raw | ConvertFrom-Json).'18'
        $expected | Should -Not -BeNullOrEmpty
        $row = Get-Content -LiteralPath $global:PublishTestUploaded | Select-Object -First 1 | ConvertFrom-Json
        $row.seeder_package_version | Should -Be $expected
    }

    It 'skips the Azure Monitor queries when there is no usable window' {
        @($global:PublishTestAzCalls | Where-Object { $_ -like 'monitor metrics*' }).Count | Should -Be 0
    }
}
