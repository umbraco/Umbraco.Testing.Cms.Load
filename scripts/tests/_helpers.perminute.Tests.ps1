# Verifies the per-minute latency series offline: Parse-JmeterCsv
# -CollectPerMinute buckets kept samples by the minute they started in (after
# the ramp cutoff and label filter), and Get-PerMinuteLatencyPoints turns the
# buckets into p50/p95/max series points in time order.
BeforeAll {
    . "$PSScriptRoot/../_helpers.ps1"

    # Minute 0 = 2026-10-19T06:30:00Z.
    $script:m0 = [DateTimeOffset]::Parse('2026-10-19T06:30:00Z').ToUnixTimeMilliseconds()
    function New-Csv([string[]]$Rows) {
        $path = Join-Path $TestDrive ("{0}.csv" -f [guid]::NewGuid())
        $lines = @('timeStamp,elapsed,label,responseCode,responseMessage,threadName,dataType,success') + $Rows
        Set-Content -Path $path -Value $lines
        return $path
    }
}

Describe 'Parse-JmeterCsv -CollectPerMinute' {
    It 'buckets samples by start minute' {
        $path = New-Csv @(
            "$($m0 + 1000),20,Homepage,200,OK,t1,text,true",
            "$($m0 + 59999),30,Detail,200,OK,t1,text,true",
            "$($m0 + 60000),9000,Homepage,200,OK,t1,text,true"
        )
        $r = Parse-JmeterCsv -Path $path -CollectPerMinute
        $r.ByMinute.Count | Should -Be 2
        @($r.ByMinute[$m0]) | Should -Be @(20, 30)
        @($r.ByMinute[$m0 + 60000]) | Should -Be @(9000)
    }
    It 'leaves out ramp-window and filtered-label samples, like the other stats' {
        $path = New-Csv @(
            "$($m0 + 1000),500,Homepage,200,OK,t1,text,true",
            "$($m0 + 61000),40,Homepage,200,OK,t1,text,true",
            "$($m0 + 62000),700,01. Open page,200,OK,t1,text,true"
        )
        $r = Parse-JmeterCsv -Path $path -CollectPerMinute -RampCutoffMs ($m0 + 60000)
        $r.ByMinute.Count | Should -Be 1
        @($r.ByMinute[$m0 + 60000]) | Should -Be @(40)
    }
    It 'returns no buckets without the switch' {
        $path = New-Csv @("$($m0 + 1000),20,Homepage,200,OK,t1,text,true")
        (Parse-JmeterCsv -Path $path).ByMinute | Should -BeNullOrEmpty
    }
}

Describe 'Get-PerMinuteLatencyPoints' {
    It 'emits p50/p95/max per minute in time order' {
        $byMinute = @{
            ($m0 + 60000) = [System.Collections.Generic.List[int]]@(9000)
            $m0           = [System.Collections.Generic.List[int]]@(30, 10, 20)
        }
        $points = @(Get-PerMinuteLatencyPoints -ByMinute $byMinute)
        $points.Count | Should -Be 6
        $points[0].TimeGenerated | Should -Be '2026-10-19T06:30:00.0000000Z'
        ($points | Where-Object { $_.TimeGenerated -like '*06:30:00*' -and $_.metric_name -eq 'latency_p50_ms' }).value | Should -Be 20
        ($points | Where-Object { $_.TimeGenerated -like '*06:30:00*' -and $_.metric_name -eq 'latency_max_ms' }).value | Should -Be 30
        ($points | Where-Object { $_.TimeGenerated -like '*06:31:00*' -and $_.metric_name -eq 'latency_p95_ms' }).value | Should -Be 9000
    }
    It 'returns nothing for no buckets' {
        @(Get-PerMinuteLatencyPoints -ByMinute @{}).Count | Should -Be 0
    }
}
