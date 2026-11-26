BeforeAll {
    . "$PSScriptRoot/../check-client-regression.ps1" -DotSourceForTest
}

Describe 'Test-ClientRegression' {
    It 'flags a metric whose candidate median exceeds baseline median x threshold' {
        $r = Test-ClientRegression -CandidateMedian 130 -BaselineMedians @(100,100,100) -Threshold 0.10
        $r.Regressed | Should -BeTrue
    }
    It 'passes a metric within threshold' {
        $r = Test-ClientRegression -CandidateMedian 105 -BaselineMedians @(100,100,100) -Threshold 0.10
        $r.Regressed | Should -BeFalse
    }
    It 'reports insufficient baseline when fewer than MinBaselineRuns' {
        $r = Test-ClientRegression -CandidateMedian 999 -BaselineMedians @(100) -Threshold 0.10 -MinBaselineRuns 3
        $r.Insufficient | Should -BeTrue
        $r.Regressed | Should -BeFalse
    }
}

Describe 'Select-ClientBaseline' {
    BeforeAll {
        function New-Row($id, $sku = 'P0v3', $dtu = 20, $preset = 'Medium') {
            [pscustomobject]@{ run_id = $id; app_service_sku = $sku; pool_dtu_max = $dtu; seeder_preset = $preset; count = 10 }
        }
    }
    It 'keeps only earlier runs on the candidate setup' {
        $rows = @((New-Row 'a'), (New-Row 'b' 'P1v3'), (New-Row 'c' 'P0v3' 50), (New-Row 'd' 'P0v3' 20 'Small'), (New-Row 'e'), (New-Row 'cand'))
        $b = Select-ClientBaseline -Ordered $rows -Window 5
        ($b.Rows.run_id -join ',') | Should -Be 'a,e'
        $b.Excluded | Should -Be 3
    }
    It 'takes the newest runs when there are more than the window' {
        $rows = @('a','b','c','d','cand' | ForEach-Object { New-Row $_ })
        (Select-ClientBaseline -Ordered $rows -Window 2).Rows.run_id -join ',' | Should -Be 'c,d'
    }
    It 'has no baseline for a single run' {
        (Select-ClientBaseline -Ordered @((New-Row 'cand'))).Rows.Count | Should -Be 0
    }
}

Describe 'Test-ClientComplete' {
    It 'flags a candidate with fewer repetitions than its baseline runs' {
        $r = Test-ClientComplete -CandidateCount 3 -BaselineRows @([pscustomobject]@{ count = 10 }, [pscustomobject]@{ count = 9 })
        $r.Complete | Should -BeFalse
        $r.Expected | Should -Be 10
    }
    It 'accepts a full set' {
        (Test-ClientComplete -CandidateCount 10 -BaselineRows @([pscustomobject]@{ count = 10 })).Complete | Should -BeTrue
    }
    It 'uses -ExpectedReps over the baseline when given' {
        (Test-ClientComplete -CandidateCount 10 -BaselineRows @([pscustomobject]@{ count = 10 }) -ExpectedReps 20).Complete | Should -BeFalse
    }
    It 'does not judge when there is nothing to compare with' {
        (Test-ClientComplete -CandidateCount 3 -BaselineRows @()).Complete | Should -BeTrue
    }
}
