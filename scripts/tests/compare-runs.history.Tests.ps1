# History-mode compare-runs.ps1 against a fake history blob, with `az` stubbed.
# Guards which runs a median is taken over: a wrong pick doesn't fail, it just
# reports a different number, so nothing else would catch a regression here.
Describe 'compare-runs history mode: which runs a median rests on' {
    BeforeAll {
        $script:blobDir = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid()))
        $global:CompareRunsTestBlob = Join-Path $blobDir 'summary.ndjson'

        function script:New-Row {
            param($Id, $Version, $Day, $P95, $Err = 0, $Sampler = 'Homepage', $Sku = 'P0v3')
            [ordered]@{
                run_id = "$Id"; methodology_version = 2; run_started_at = "2026-11-${Day}T10:00:00Z"
                umbraco_version = $Version; infra_tier = 'Starter'; scenario = 'Default'; scenario_name = $Sampler
                app_service_sku = $Sku; pool_dtu_max = 20; seeder_preset = 'Medium'; seeder_package_version = 'build-1'
                user_count = 50; spawn_rate = 10; duration_seconds = 300; parse_status = 'ok'; cold_start = $false
                request_count = 1000; failure_count = [int](1000 * $Err); error_rate = $Err
                avg_ms = $P95 / 2; p50_ms = $P95 / 2; p90_ms = $P95 - 5; p95_ms = $P95; p99_ms = $P95 + 50
                max_ms = $P95 + 200; min_ms = 10
                seeded_content_total = 500; seeded_root_sections = 5; seeded_media_images = 50; seeded_media_files = 10
            } | ConvertTo-Json -Compress
        }

        $rows = @()
        # 18.3.2: an older clean run, five queued runs (the last a 900 ms outlier
        # from an environment hiccup), then a NEWER run on an overridden SKU.
        $rows += New-Row 190 '18.3.2' '10' 215
        $p18 = 200, 210, 190, 205, 900
        for ($i = 0; $i -lt 5; $i++) { $rows += New-Row (201 + $i * 2) '18.3.2' "2$i" $p18[$i] }
        $rows += New-Row 211 '18.3.2' '25' 120 0 'Homepage' 'P3v3'
        # 19.0.0-rc1: five queued runs; two fail fast (40% errors, tiny p95).
        $p19 = 180, 20, 185, 25, 182; $e19 = 0, 0.4, 0, 0.4, 0
        for ($i = 0; $i -lt 5; $i++) { $rows += New-Row (202 + $i * 2) '19.0.0-rc1' "2$i" $p19[$i] $e19[$i] }
        # The same version on another tier: bigger SKU and DTU cap, as tiers have.
        $pro = (New-Row 301 '18.3.2' '24' 150 0 'Homepage' 'P2v3' | ConvertFrom-Json)
        $pro.infra_tier = 'Pro'; $pro.pool_dtu_max = 100
        $rows += ($pro | ConvertTo-Json -Compress)
        # A row from before jmeter_test_name was published: a raw backoffice
        # request, not a sampler. It must not come back as a cell.
        $rows += New-Row 150 '18.3.2' '05' 9999 0 'GET /umbraco/management/api/v1/language'
        $rows | Set-Content -LiteralPath $global:CompareRunsTestBlob

        # compare-runs.ps1 reaches storage only through `az`; a function wins
        # over the executable, so no Azure login or network is involved.
        function global:az {
            $a = $args -join ' '
            if ($a -like 'storage account keys list*') { return 'fake-key' }
            if ($a -like 'storage blob list*') { return '["Default/x/summary.ndjson"]' }
            if ($a -like 'storage blob download*') {
                Copy-Item -LiteralPath $global:CompareRunsTestBlob -Destination $args[[array]::IndexOf($args, '--file') + 1] -Force
                return
            }
            throw "unexpected az call in test: $a"
        }

        $script:queued = '201,203,205,207,209,202,204,206,208,210'
        $script:compare = {
            param([hashtable]$Extra)
            $common = @{ Scenario = 'Default'; Tier = 'Starter'; HistoryResourceGroup = 'rg'; StorageAccountName = 'sa'; ContainerName = 'c'
                         Versions = '18.3.2,19.0.0-rc1'; Aggregate = 'median' }
            (& "$PSScriptRoot/../compare-runs.ps1" @common @Extra 6>$null) -join "`n"
        }
    }
    AfterAll {
        Remove-Item -Path Function:\az -ErrorAction SilentlyContinue
        Remove-Variable -Name CompareRunsTestBlob -Scope Global -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:blobDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'keeps a newer run on another setup out of the median, and says the median is short' {
        # Unscoped, the newest 18.3.2 run is the SKU override, and the newest run
        # decides the setup - so it stands alone rather than joining the others.
        $out = & $compare @{}
        $out | Should -Match '\*\*18\.3\.2\*\*: 1 run\(s\) \(#211\)'
        $out | Should -Match 'Fewer runs than the 5 asked for:\*\* 18\.3\.2 \(n=1\)'
        $out | Should -Match 'not on the same setup\*\* \(app SKU differ'
    }

    It 'pins the median to exactly the runs named in -RunIds' {
        $out = & $compare @{ RunIds = $queued }
        $out | Should -Match '\*\*18\.3\.2\*\*: 5 run\(s\) \(#201, #203, #205, #207, #209\)'
        $out | Should -Match '\*\*19\.0\.0-rc1\*\*: 5 run\(s\) \(#202, #204, #206, #208, #210\)'
        $out | Should -Not -Match 'Fewer runs than'
        # median(200,210,190,205,900) = 205; the 900 ms outlier does not move it.
        $out | Should -Match '## p95 \(ms\)[\s\S]*?\| `Homepage` \| 205 '
    }

    It 'replaces a run excluded by hand with the next older like-for-like run' {
        $out = & $compare @{ ExcludeRunIds = '211,#209' }
        $out | Should -Match 'Excluded by you:\*\* #211, #209'
        $out | Should -Match '\*\*18\.3\.2\*\*: 5 run\(s\) \(#190, #201, #203, #205, #207\)'
        # median(215,200,210,190,205) = 205, and the spread collapses without the outlier.
        $out | Should -Match '## p95 \(ms\)[\s\S]*?\| `Homepage` \| 205 ±9 '
    }

    It 'shows the worst run next to a median error rate that hides failing runs' {
        # Two of five runs at 40% errors: the median error rate is still 0%.
        $out = & $compare @{ RunIds = $queued }
        $out | Should -Match '\| `Homepage` \| 0% \(n=5\) \| 0% \(worst 40%, n=5\) \|'
    }

    It 'leaves runs over -MaxErrorRate out of latency only, and names them' {
        $without = & $compare @{ RunIds = $queued }
        # With the failing runs in: median(180,20,185,25,182) = 180, spread 78.
        $without | Should -Match '## p95 \(ms\)[\s\S]*?\| `Homepage` \| 205 ±\d+ \| 180 ±78 \|'

        $out = & $compare @{ RunIds = $queued; MaxErrorRate = 5 }
        # Without them: median(180,185,182) = 182 over the 3 runs that didn't fail.
        $out | Should -Match '## p95 \(ms\)[\s\S]*?\| `Homepage` \| 205 ±\d+ \| 182 ±2 \(n=3\) \|'
        $out | Should -Match 'Left out of the latency medians - error rate over 5%'
        $out | Should -Match '\*\*19\.0\.0-rc1\*\*: #204 `Homepage` \(40%\), #208 `Homepage` \(40%\)'
        # Still counted where it matters: all five runs, two flagged.
        $out | Should -Match '0% \(worst 40%, n=5, 2 over limit\)'
        # Failing runs are a result, not a mistake: no older run is pulled in.
        $out | Should -Match '\*\*19\.0\.0-rc1\*\*: 5 run\(s\) \(#202, #204, #206, #208, #210\)'
    }

    It 'calls a version failing when every run is over the limit' {
        # Only the two failing 19.0.0-rc1 runs (#204, #208) are in scope.
        $out = & $compare @{ RunIds = '201,203,204,208'; MaxErrorRate = 5 }
        $out | Should -Match 'limited to runs #201, #203, #204, #208'
        $out | Should -Match 'Failing, not noisy: 19\.0\.0-rc1 \(every run over the limit on `Homepage`\)'
        # The latency shown is that of the failing runs: marked, and NOT turned
        # into a change. Instant failures are fast, so a change here would read
        # as a ~90% speed-up for the version that broke.
        $out | Should -Match '## p95 \(ms\)[\s\S]*?\| `Homepage` \| \d+ ±\d+ \| \d+ ! \| n/c \|'
        $out | Should -Not -Match '\*\*-\d+%\*\*'
    }

    It 'keeps raw management-API rows from before jmeter_test_name out of the report' {
        $out = & $compare @{ RunIds = "$queued,150" }
        $out | Should -Not -Match 'management/api'
        # #150 is named in the scope line (it was asked for) but backs no median.
        $out | Should -Match '\*\*18\.3\.2\*\*: 5 run\(s\) \(#201, #203, #205, #207, #209\)'
    }

    It 'cuts -Since at the UTC time given, whatever the local time zone' {
        # Runs start at 10:00Z. A cut 30 minutes before the day-22 runs must keep
        # them; shifting run times by the local offset used to drop them on UTC+1.
        $out = & $compare @{ Since = [datetime]::new(2026, 11, 22, 9, 30, 0, [DateTimeKind]::Utc); ExcludeRunIds = '211' }
        $out | Should -Match '\*\*18\.3\.2\*\*: 3 run\(s\) \(#205, #207, #209\)'
        $out | Should -Match 'runs started on or after 22-11-2026 09:30 UTC'
        # ...and one 30 minutes after them must not.
        $out = & $compare @{ Since = [datetime]::new(2026, 11, 22, 10, 30, 0, [DateTimeKind]::Utc); ExcludeRunIds = '211' }
        $out | Should -Match '\*\*18\.3\.2\*\*: 2 run\(s\) \(#207, #209\)'
    }

    It 'warns in pair mode when the two sides ran on different hardware' {
        $common = @{ Scenario = 'Default'; Tier = 'Starter'; HistoryResourceGroup = 'rg'; StorageAccountName = 'sa'; ContainerName = 'c' }
        # Unscoped, 18.3.2's newest run is the P3v3 override (#211), so its side
        # is that run alone, against 19.0.0-rc1 on P0v3.
        $out = (& "$PSScriptRoot/../compare-runs.ps1" @common -BaselineVersion 18.3.2 -CandidateVersion 19.0.0-rc1 -Aggregate median 6>$null) -join "`n"
        $out | Should -Match 'not on the same setup:\*\* app SKU \(18\.3\.2 / Starter: P3v3; 19\.0\.0-rc1 / Starter: P0v3\)'
        # Same hardware on both sides: no warning.
        $out = (& "$PSScriptRoot/../compare-runs.ps1" @common -BaselineVersion 18.3.2 -CandidateVersion 19.0.0-rc1 -Aggregate median -ExcludeRunIds 211 6>$null) -join "`n"
        $out | Should -Not -Match 'not on the same setup'
    }

    It 'does not blame an override for the SKU and DTU cap two tiers differ on by design' {
        $common = @{ Scenario = 'Default'; HistoryResourceGroup = 'rg'; StorageAccountName = 'sa'; ContainerName = 'c' }
        $out = (& "$PSScriptRoot/../compare-runs.ps1" @common -Version 18.3.2 -BaselineTier Starter -CandidateTier Pro -Aggregate median -ExcludeRunIds 211 6>$null) -join "`n"
        $out | Should -Match 'Candidate: 18\.3\.2 / Pro - median across 1 run\(s\) \(#301\)'
        $out | Should -Not -Match 'not on the same setup'
    }

    It 'computes no change in pair mode against a side whose every run is over the limit' {
        $common = @{ Scenario = 'Default'; Tier = 'Starter'; HistoryResourceGroup = 'rg'; StorageAccountName = 'sa'; ContainerName = 'c' }
        $out = (& "$PSScriptRoot/../compare-runs.ps1" @common -BaselineVersion 18.3.2 -CandidateVersion 19.0.0-rc1 `
                    -Aggregate median -RunIds '201,203,204,208' -MaxErrorRate 5 6>$null) -join "`n"
        $out | Should -Match '\| `Homepage` \| \d+ \| \d+ ! \| n/c \| n/c \| n/c \|'
        $out | Should -Not -Match '\*\*-\d+%\*\*'
    }

    It 'honours -Since (and the legacy median5 spelling)' {
        $common = @{ Scenario = 'Default'; Tier = 'Starter'; HistoryResourceGroup = 'rg'; StorageAccountName = 'sa'; ContainerName = 'c' }
        $out = (& "$PSScriptRoot/../compare-runs.ps1" @common -BaselineVersion 18.3.2 -CandidateVersion 19.0.0-rc1 `
                    -Aggregate median5 -Since '2026-11-22' -ExcludeRunIds 211 6>$null) -join "`n"
        # Days 22-24 only: #205, #207, #209 and #206, #208, #210.
        $out | Should -Match 'Baseline:  18\.3\.2 / Starter - median across 3 run\(s\) \(#205, #207, #209\)'
        $out | Should -Match 'Candidate: 19\.0\.0-rc1 / Starter - median across 3 run\(s\) \(#206, #208, #210\)'
    }
}
