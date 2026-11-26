BeforeAll {
    . "$PSScriptRoot/../cost-report.ps1" -DotSourceForTest

    function New-ClassLine($time, $class, $n, $ms, $sqlN, $sqlMs, $commitMs = 0) {
        [ordered]@{ '@t' = $time; '@mt' = 'LoadTestHeartbeat cost: class={Class} n={Requests} ms={Ms} sql_n={SqlCommands} sql_ms={SqlMs} commit_ms={CommitMs}'
            Class = $class; Requests = $n; Ms = $ms; SqlCommands = $sqlN; SqlMs = $sqlMs; CommitMs = $commitMs } | ConvertTo-Json -Compress
    }
    function New-TotalLine($time, $n, $cpu, $allocMb, $gen0 = 0) {
        [ordered]@{ '@t' = $time; '@mt' = 'LoadTestHeartbeat cost total: requests={Requests} cpu_ms={CpuMs} alloc_mb={AllocMb} gen0={Gen0} gen1={Gen1} gen2={Gen2}'
            Requests = $n; CpuMs = $cpu; AllocMb = $allocMb; Gen0 = $gen0; Gen1 = 0; Gen2 = 0 } | ConvertTo-Json -Compress
    }
}

Describe 'Get-RunCost' {
    BeforeAll {
        $script:lines = @(
            (New-ClassLine '2026-11-26T10:00:59Z' 'Page' 10 100 0 0),
            (New-TotalLine '2026-11-26T10:01:00Z' 10 500 10 1),
            (New-ClassLine '2026-11-26T10:01:59Z' 'Page' 30 60 0 0),
            (New-ClassLine '2026-11-26T10:01:59Z' 'FormPost' 5 900 200 400 100),
            (New-TotalLine '2026-11-26T10:02:00Z' 35 700 20 2),
            (New-ClassLine '2026-11-26T10:02:59Z' 'FormPost' 5 1100 200 600 150),
            (New-TotalLine '2026-11-26T10:03:00Z' 5 300 5 1),
            '{"@t":"2026-11-26T10:03:01Z","@mt":"LoadTestHeartbeat beat: late_ms={LateMs}","LateMs":3}',
            'not json at all LoadTestHeartbeat cost'
        )
    }
    It 'adds up every minute per kind of request and for the process' {
        $c = Get-RunCost -Lines $script:lines
        $c.Minutes | Should -Be 3
        ($c.Classes | Where-Object Class -eq 'Page').Requests | Should -Be 40
        ($c.Classes | Where-Object Class -eq 'FormPost').SqlCommands | Should -Be 400
        $c.Total.Requests | Should -Be 50
        $c.Total.CpuMs | Should -Be 1500
        $c.Total.Gen0 | Should -Be 4
    }
    It 'leaves out the first minutes when asked' {
        $c = Get-RunCost -Lines $script:lines -SkipMinutes 1
        $c.Minutes | Should -Be 2
        ($c.Classes | Where-Object Class -eq 'Page').Requests | Should -Be 30
        $c.Total.Requests | Should -Be 40
    }
    It 'has nothing left when every minute is skipped' {
        $c = Get-RunCost -Lines $script:lines -SkipMinutes 3
        $c.Minutes | Should -Be 0
        $c.Classes.Count | Should -Be 0
        $c.Total.Requests | Should -Be 0
    }
    It 'copes with a log that has no cost lines' {
        (Get-RunCost -Lines @()).Minutes | Should -Be 0
    }
}

Describe 'Format-CostChange and Get-PerRequest' {
    It 'shows the difference with its sign and percentage' {
        Format-CostChange 38 40 2 | Should -Be '+2.00 (+5%)'
        Format-CostChange 40 38 2 | Should -Be '-2.00 (-5%)'
    }
    It 'shows equal values as =' { Format-CostChange 38 38 2 | Should -Be '=' }
    It 'gives no percentage against a zero baseline' { Format-CostChange 0 1 2 | Should -Be '+1.00' }
    It 'is empty when a side is missing' { Format-CostChange $null 1 | Should -Be '' }
    It 'does not divide by zero requests' { Get-PerRequest 10 0 | Should -BeNullOrEmpty }
    It 'uses a decimal point whatever the machine culture' {
        $old = [cultureinfo]::CurrentCulture
        try { [cultureinfo]::CurrentCulture = 'da-DK'; Format-CostChange 1 1.5 2 | Should -Be '+0.50 (+50%)' } finally { [cultureinfo]::CurrentCulture = $old }
    }
}
