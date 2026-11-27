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

Describe 'Get-RunCost with a time window' {
    It 'keeps only the minutes inside -From and -To' {
        $lines = @(
            (New-ClassLine '2026-11-26T10:00:59Z' 'Page' 10 100 0 0), (New-TotalLine '2026-11-26T10:01:00Z' 10 500 10),
            (New-ClassLine '2026-11-26T10:01:59Z' 'Page' 30 60 0 0),  (New-TotalLine '2026-11-26T10:02:00Z' 30 700 20),
            (New-ClassLine '2026-11-26T10:02:59Z' 'Page' 7 60 0 0),   (New-TotalLine '2026-11-26T10:03:00Z' 7 300 5)
        )
        $c = Get-RunCost -Lines $lines -From ([datetime]::Parse('2026-11-26T10:01:30Z').ToUniversalTime()) -To ([datetime]::Parse('2026-11-26T10:02:30Z').ToUniversalTime())
        $c.Minutes | Should -Be 1
        ($c.Classes | Where-Object Class -eq 'Page').Requests | Should -Be 30
        $c.Total.CpuMs | Should -Be 700
    }
}

Describe 'Get-RunCost with the process figures added later' {
    BeforeAll {
        function New-FullTotal($time, $n, $cpu, $exc, $jit, $jitTotal, $asm, $heap, $ws) {
            [ordered]@{ '@t' = $time; '@mt' = 'LoadTestHeartbeat cost total: requests={Requests} cpu_ms={CpuMs} alloc_mb={AllocMb} gen0={Gen0} gen1={Gen1} gen2={Gen2} exceptions={Exceptions} jit_n={JitMethods} jit_total={JitTotal} assemblies={Assemblies} heap_mb={HeapMb} working_set_mb={WorkingSetMb}'
                Requests = $n; CpuMs = $cpu; AllocMb = 10; Gen0 = 1; Gen1 = 0; Gen2 = 0; Exceptions = $exc; JitMethods = $jit; JitTotal = $jitTotal; Assemblies = $asm; HeapMb = $heap; WorkingSetMb = $ws } | ConvertTo-Json -Compress
        }
        function New-Calibration($time, $us) {
            [ordered]@{ '@t' = $time; '@mt' = 'LoadTestHeartbeat calibration: work_us={WorkUs} runs={Runs}'; WorkUs = $us; Runs = 3 } | ConvertTo-Json -Compress
        }
        $script:full = @(
            (New-Calibration '2026-11-26T10:00:00Z' 5000),
            (New-FullTotal '2026-11-26T10:01:00Z' 1000 2000 4 300 20300 250 80 300), (New-Calibration '2026-11-26T10:01:00Z' 4000),
            (New-FullTotal '2026-11-26T10:02:00Z' 1000 2000 6 100 20400 251 90 310), (New-Calibration '2026-11-26T10:02:00Z' 4200),
            (New-FullTotal '2026-11-26T10:03:00Z' 1000 2000 0 0 20400 251 100 320),   (New-Calibration '2026-11-26T10:03:00Z' 4100)
        )
    }
    It 'sums exceptions and methods compiled, and takes the start-up work from the first kept minute' {
        $t = (Get-RunCost -Lines $script:full).Total
        $t.Exceptions | Should -Be 10
        $t.JitMethods | Should -Be 400
        $t.JitBefore | Should -Be 20000
        $t.Assemblies | Should -Be 250
    }
    It 'gives the median of heap and working set, and the fastest calibration' {
        $t = (Get-RunCost -Lines $script:full).Total
        $t.HeapMb | Should -Be 90
        $t.WorkingSetMb | Should -Be 310
        $t.CalibrationUs | Should -Be 4000
    }
    It 'cuts calibration lines by the window like the rest' {
        $t = (Get-RunCost -Lines $script:full -From ([datetime]::Parse('2026-11-26T10:01:30Z').ToUniversalTime())).Total
        $t.CalibrationUs | Should -Be 4100
        $t.JitBefore | Should -Be 20300
    }
    It 'leaves a minute of one-off compiling out of the steady CPU figure, and keeps it in the plain one' {
        $lines = @(
            (New-FullTotal '2026-11-26T10:01:00Z' 1000 2000 0 50 20000 250 80 300),
            (New-FullTotal '2026-11-26T10:02:00Z' 1000 4000 0 6500 26500 254 80 300),
            (New-FullTotal '2026-11-26T10:03:00Z' 1000 2200 0 40 26540 254 80 300)
        )
        $t = (Get-RunCost -Lines $lines).Total
        $t.CpuMs | Should -Be 8200
        $t.BurstMinutes | Should -Be 1
        $t.SteadyRequests | Should -Be 2000
        $t.SteadyCpuMs | Should -Be 4200
        $off = (Get-RunCost -Lines $lines -JitBurst 0).Total
        $off.BurstMinutes | Should -Be 0
        $off.SteadyCpuMs | Should -Be 8200
    }
    It 'finds no burst in a log without the compile counts' {
        $t = (Get-RunCost -Lines @((New-TotalLine '2026-11-26T10:01:00Z' 10 500 10))).Total
        $t.BurstMinutes | Should -Be 0
        $t.SteadyCpuMs | Should -Be 500
    }
    It 'reads a log without the new fields as missing, not zero' {
        $old = @((New-TotalLine '2026-11-26T10:01:00Z' 10 500 10))
        $t = (Get-RunCost -Lines $old).Total
        $t.Exceptions | Should -BeNullOrEmpty
        $t.HeapMb | Should -BeNullOrEmpty
        $t.CalibrationUs | Should -BeNullOrEmpty
        $t.JitBefore | Should -BeNullOrEmpty
    }
}
