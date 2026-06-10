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
