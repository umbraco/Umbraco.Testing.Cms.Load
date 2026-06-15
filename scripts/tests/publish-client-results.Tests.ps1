# Verifies the NDJSON->row transform without touching Azure: Build-ClientRows must
# turn the Playwright per-metric NDJSON into LA-shaped rows carrying run metadata.
BeforeAll {
    . "$PSScriptRoot/../publish-client-results.ps1" -DotSourceForTest
}

Describe 'Build-ClientRows' {
    It 'maps a metric NDJSON file to a row with metadata + stats' {
        $tmp = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid()))
        @'
{"metric":"cold_dashboard_load","run_id":"local","count":10,"median":130,"p75":140,"p95":160,"min":110,"max":180,"stddev":15.2,"ttfb_ms":40,"dcl_ms":200,"load_ms":300,"lcp_ms":250}
'@ | Out-File (Join-Path $tmp 'cold_dashboard_load.ndjson') -Encoding utf8

        $rows = Build-ClientRows -ResultsDir $tmp -UmbracoVersion '17.0.0' -Tier 'Starter' `
            -Scenario 'Default' -AppServiceSku 'P0v3' -PoolDtuMax 20 -SeederPreset 'Medium' `
            -BuildId '123' -Commit 'abc' -Branch 'main' -RunStartedAt '2026-06-10T00:00:00Z'

        $rows.Count | Should -Be 1
        $rows[0].metric | Should -Be 'cold_dashboard_load'
        $rows[0].median_ms | Should -Be 130
        $rows[0].umbraco_version | Should -Be '17.0.0'
        $rows[0].infra_tier | Should -Be 'Starter'
        $rows[0].run_id | Should -Be '123'
    }

    It 'maps time_to_first_edit segment medians to seg_*_ms columns' {
        $tmp = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid()))
        @'
{"metric":"time_to_first_edit","run_id":"local","count":10,"median":5000,"p75":5200,"p95":5400,"min":4800,"max":5600,"stddev":120,"seg_login_median":3000,"seg_navigate_median":1000,"seg_editor_ready_median":900,"seg_keystroke_median":40}
'@ | Out-File (Join-Path $tmp 'time_to_first_edit.ndjson') -Encoding utf8
        $rows = Build-ClientRows -ResultsDir $tmp -UmbracoVersion '17.0.0' -Tier 'Starter' `
            -Scenario 'Default' -AppServiceSku 'P0v3' -PoolDtuMax 20 -SeederPreset 'Medium' `
            -BuildId '123' -Commit 'abc' -Branch 'main' -RunStartedAt '2026-06-10T00:00:00Z'
        $rows[0].seg_login_ms | Should -Be 3000
        $rows[0].seg_keystroke_ms | Should -Be 40
    }

    It 'normalizes a space-separated pipeline timestamp to ISO-8601 (Log Analytics rejects the raw form with a 400)' {
        $tmp = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid()))
        @'
{"metric":"cold_dashboard_load","run_id":"local","count":10,"median":130,"p75":140,"p95":160,"min":110,"max":180,"stddev":15.2}
'@ | Out-File (Join-Path $tmp 'cold_dashboard_load.ndjson') -Encoding utf8
        # $(System.PipelineStartTime) format: space-separated, not ISO.
        $rows = Build-ClientRows -ResultsDir $tmp -UmbracoVersion '17.0.0' -Tier 'Starter' `
            -Scenario 'Default' -AppServiceSku 'P0v3' -PoolDtuMax 20 -SeederPreset 'Medium' `
            -BuildId '123' -Commit 'abc' -Branch 'main' -RunStartedAt '2026-06-15 13:45:30+00:00'
        $rows[0].TimeGenerated | Should -Be '2026-06-15T13:45:30.0000000Z'
    }
}
