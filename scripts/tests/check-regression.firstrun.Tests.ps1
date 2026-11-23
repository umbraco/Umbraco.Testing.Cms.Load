# check-regression.ps1 when history holds no metric rows at all, with `az`
# stubbed. That is the normal state on the first run of a scenario or major -
# and also what a run looks like when every tier it attempted fast-failed and
# left only placeholder rows. The two must not read the same: the second used
# to be reported as "expected on the first run".
Describe 'check-regression: no metric rows in history' {
    BeforeAll {
        $script:work = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid()))
        $global:RegressionTestBlob = Join-Path $work 'summary.ndjson'

        function global:az {
            $a = $args -join ' '
            if ($a -like 'storage account keys list*') { return 'fake-key' }
            if ($a -like 'storage blob list*') { return '["Default/19/summary.ndjson"]' }
            if ($a -like 'storage blob download*') {
                Copy-Item -LiteralPath $global:RegressionTestBlob -Destination $args[[array]::IndexOf($args, '--file') + 1] -Force
                return
            }
            throw "unexpected az call in test: $a"
        }

        # A placeholder row: what publish-load-test-results.ps1 writes for a
        # tier that never produced results (no scenario_name, no metrics).
        function script:New-Placeholder($RunId, $Tier) {
            [ordered]@{ run_id = "$RunId"; run_started_at = '2026-11-23T10:00:00Z'; umbraco_version = '19.0.0-rc1'
                        infra_tier = $Tier; scenario = 'Default'; parse_status = 'no_results_dir' } | ConvertTo-Json -Compress
        }

        $script:check = {
            param([string]$RunId, [string]$Report)
            # Child process: the script ends in `exit`, which would end the test run.
            # The az stub is re-declared there from this session's definition.
            $azBody = (Get-Item Function:\az).ScriptBlock.ToString()
            $cmd = "function global:az { $azBody }; `$global:RegressionTestBlob = '$($global:RegressionTestBlob)'; " +
                   "& '$PSScriptRoot/../check-regression.ps1' -Scenario Default -HistoryResourceGroup rg -StorageAccountName sa -ContainerName c -RunId $RunId -OutputPath '$Report'; exit `$LASTEXITCODE"
            $log = pwsh -NoProfile -Command $cmd 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Log = $log; Report = (Get-Content -LiteralPath $Report -Raw) }
        }
    }
    AfterAll {
        Remove-Item -Path Function:\az -ErrorAction SilentlyContinue
        Remove-Variable -Name RegressionTestBlob -Scope Global -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:work -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'names the tiers this run attempted and got nothing from, and warns' {
        @((New-Placeholder 500 'Starter'), (New-Placeholder 500 'Standard')) | Set-Content -LiteralPath $global:RegressionTestBlob
        $r = & $check '500' (Join-Path $work 'dead.md')
        $r.ExitCode | Should -Be 0
        $r.Report | Should -Match '\*\*19\.0\.0-rc1 / Starter\*\*: attempted but published no metric rows'
        $r.Report | Should -Match '\*\*19\.0\.0-rc1 / Standard\*\*: attempted but published no metric rows'
        $r.Report | Should -Not -Match 'expected on the first run'
        $r.Log | Should -Match "task\.logissue type=warning\]Run '500' published no metric rows for: 19\.0\.0-rc1/Standard, 19\.0\.0-rc1/Starter"
    }

    It 'reports a plan that ran and published nothing as a failure, not as a plan that did not run' {
        function New-Metric($RunId, $Day, $Plan) {
            [ordered]@{ run_id = "$RunId"; run_started_at = "2026-11-${Day}T10:00:00Z"; umbraco_version = '19.0.0-rc1'
                        infra_tier = 'Starter'; scenario = 'Default'; scenario_name = "$Plan / 01. Step"; jmeter_test_name = $Plan
                        parse_status = 'ok'; cold_start = $false; user_count = 15; spawn_rate = 5; duration_seconds = 300
                        methodology_version = 1; p95_ms = 100; p99_ms = 150; error_rate = 0 } | ConvertTo-Json -Compress
        }
        $rows = @()
        foreach ($d in 18..21) { $rows += New-Metric (400 + $d) "$d" 'ViewHomePage'; $rows += New-Metric (400 + $d) "$d" 'SaveContent' }
        # Run 500: ViewHomePage is fine; SaveContent left only its placeholder.
        $rows += New-Metric 500 '22' 'ViewHomePage'
        $placeholder = (New-Placeholder 500 'Starter' | ConvertFrom-Json)
        $placeholder | Add-Member jmeter_test_name 'SaveContent'
        $rows += ($placeholder | ConvertTo-Json -Compress)
        $rows | Set-Content -LiteralPath $global:RegressionTestBlob

        $r = & $check '500' (Join-Path $work 'plan.md')
        $r.Report | Should -Match '\*\*SaveContent\*\*: attempted on 19\.0\.0-rc1 / Starter but published no metric rows'
        $r.Report | Should -Not -Match "SaveContent\*\*: all \d+ cell\(s\) absent - this plan didn't run"
        $r.Log | Should -Match "task\.logissue type=warning\]No comparable rows from run '500' for: SaveContent"
    }

    It 'still calls a plan with no row at all from this run one that did not run' {
        # Same history, but run 500 never touched SaveContent (trimmed from backofficePlans).
        $kept = @(Get-Content -LiteralPath $global:RegressionTestBlob | Where-Object { $_ -notmatch '"no_results_dir"' })
        $kept | Set-Content -LiteralPath $global:RegressionTestBlob
        $r = & $check '500' (Join-Path $work 'trimmed.md')
        $r.Report | Should -Match "\*\*SaveContent\*\*: all 1 cell\(s\) absent - this plan didn't run"
        $r.Log | Should -Not -Match 'task\.logissue type=warning'
    }

    It 'still reads as a plain first run when this run left no placeholder rows' {
        # The only rows belong to another run.
        @((New-Placeholder 499 'Starter')) | Set-Content -LiteralPath $global:RegressionTestBlob
        $r = & $check '500' (Join-Path $work 'first.md')
        $r.ExitCode | Should -Be 0
        $r.Report | Should -Match 'expected on the first run'
        $r.Log | Should -Not -Match 'task\.logissue'
    }
}
