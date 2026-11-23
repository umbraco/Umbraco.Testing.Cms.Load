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

    It 'still reads as a plain first run when this run left no placeholder rows' {
        # The only rows belong to another run.
        @((New-Placeholder 499 'Starter')) | Set-Content -LiteralPath $global:RegressionTestBlob
        $r = & $check '500' (Join-Path $work 'first.md')
        $r.ExitCode | Should -Be 0
        $r.Report | Should -Match 'expected on the first run'
        $r.Log | Should -Not -Match 'task\.logissue'
    }
}
