#requires -Version 7.3

# Cost per operation, from the Heartbeat scenario's "LoadTestHeartbeat cost"
# lines in a run's Umbraco log (raw/umbraco-logs/ in history storage, or the
# build artifact).
#
# Response times at low load vary by tens of percent between identical runs, so
# a version difference in them needs many runs to show. What an operation COSTS
# - SQL commands, SQL time, CPU and memory allocated per request - barely
# varies, so one run per version is enough to compare. This script prints that
# cost per kind of request for each run, and the difference between the first
# run (the baseline) and every other.
#
#   ./cost-report.ps1 -Run '17.8.2=C:\runs\305956\umbraco-logs', '19.0.0-rc1=C:\runs\305998\umbraco-logs'
#   ./cost-report.ps1 -Run 'a=...', 'b=...' -SkipMinutes 5 -OutCsv cost.csv
#
# -Run          label=path pairs. The path is a log file or a folder of
#               UmbracoTraceLog*.json files. The first is the baseline.
# -SkipMinutes  minutes of cost lines to leave out at the start of each run
#               (warm-up and settle-in). Default 0: a caller that wants the
#               measured window passes the settle-in.
# -From, -To    keep only cost lines logged in this window (UTC, any format
#               [datetime] reads, e.g. 2026-11-26T08:05:09Z). A pipeline run's
#               log also holds the minutes the site spent being provisioned
#               and warmed up, in earlier processes, so for those give the
#               measured window here rather than counting minutes to skip.
# -MinRequests  kinds of request with fewer requests than this are left out of
#               the tables: a cost per request over a handful is noise.
# -OutCsv       also write every figure, one row per run and kind of request,
#               as CSV (invariant culture, comma-separated).

[CmdletBinding()]
param(
    [string[]]$Run,
    [int]$SkipMinutes = 0,
    [string]$From,
    [string]$To,
    [int]$MinRequests = 20,
    [string]$OutCsv,
    [string]$OutputPath,
    [switch]$DotSourceForTest
)

$ErrorActionPreference = 'Stop'
$invariant = [System.Globalization.CultureInfo]::InvariantCulture

# One run's cost lines -> totals per kind of request, plus the process totals.
# $Lines are the raw JSON log lines; anything that is not a cost line is ignored.
function Get-RunCost {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Lines,
        [int]$SkipMinutes = 0,
        [Nullable[datetime]]$From = $null,
        [Nullable[datetime]]$To = $null
    )
    $classRows = [System.Collections.Generic.List[object]]::new()
    $totalRows = [System.Collections.Generic.List[object]]::new()
    foreach ($line in $Lines) {
        if (-not $line.Contains('LoadTestHeartbeat cost')) { continue }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        $template = [string]$o.'@mt'
        $when = ([datetime]$o.'@t').ToUniversalTime()
        if ($null -ne $From -and $when -lt $From) { continue }
        if ($null -ne $To -and $when -gt $To) { continue }
        if ($template.StartsWith('LoadTestHeartbeat cost total:')) {
            $totalRows.Add([pscustomobject]@{ When = $when; Requests = [long]$o.Requests; CpuMs = [long]$o.CpuMs; AllocMb = [long]$o.AllocMb; Gen0 = [long]$o.Gen0; Gen1 = [long]$o.Gen1; Gen2 = [long]$o.Gen2 })
        } elseif ($template.StartsWith('LoadTestHeartbeat cost:')) {
            $classRows.Add([pscustomobject]@{ When = $when; Class = [string]$o.Class; Requests = [long]$o.Requests; Ms = [long]$o.Ms; SqlCommands = [long]$o.SqlCommands; SqlMs = [long]$o.SqlMs; CommitMs = [long]$o.CommitMs })
        }
    }

    # A minute is one "cost total" line; the lines per kind share its timestamp
    # to within the same log flush, so cut both by the total lines' times.
    $minutes = @($totalRows | Sort-Object When)
    $cutoff = if ($SkipMinutes -gt 0 -and $minutes.Count -gt $SkipMinutes) { $minutes[$SkipMinutes - 1].When } else { [datetime]::MinValue }
    if ($SkipMinutes -gt 0 -and $minutes.Count -le $SkipMinutes) { $cutoff = [datetime]::MaxValue }
    $keptTotals = @($minutes | Where-Object { $_.When -gt $cutoff })
    $keptClasses = @($classRows | Where-Object { $_.When -gt $cutoff })

    $classes = foreach ($group in ($keptClasses | Group-Object Class | Sort-Object Name)) {
        $n = ($group.Group | Measure-Object Requests -Sum).Sum
        [pscustomobject]@{
            Class       = $group.Name
            Requests    = [long]$n
            Ms          = [long]($group.Group | Measure-Object Ms -Sum).Sum
            SqlCommands = [long]($group.Group | Measure-Object SqlCommands -Sum).Sum
            SqlMs       = [long]($group.Group | Measure-Object SqlMs -Sum).Sum
            CommitMs    = [long]($group.Group | Measure-Object CommitMs -Sum).Sum
        }
    }
    $sum = { param($name) [long](($keptTotals | Measure-Object $name -Sum).Sum ?? 0) }
    [pscustomobject]@{
        Minutes = $keptTotals.Count
        Classes = @($classes)
        Total   = [pscustomobject]@{
            Requests = (& $sum 'Requests'); CpuMs = (& $sum 'CpuMs'); AllocMb = (& $sum 'AllocMb')
            Gen0 = (& $sum 'Gen0'); Gen1 = (& $sum 'Gen1'); Gen2 = (& $sum 'Gen2')
        }
    }
}

# total / requests, or $null when there is nothing to divide by.
function Get-PerRequest {
    param([double]$Total, [double]$Requests)
    if ($Requests -le 0) { return $null }
    $Total / $Requests
}

# "+2.00 (+5%)" for candidate against baseline; "=" when equal; "" when either is missing.
function Format-CostChange {
    param($Baseline, $Candidate, [int]$Decimals = 2)
    if ($null -eq $Baseline -or $null -eq $Candidate) { return '' }
    $diff = [double]$Candidate - [double]$Baseline
    if ([math]::Abs($diff) -lt [math]::Pow(10, -$Decimals) / 2) { return '=' }
    $sign = if ($diff -gt 0) { '+' } else { '' }
    $text = $sign + $diff.ToString("F$Decimals", $invariant)
    if ([double]$Baseline -ne 0) { $text += ' (' + $sign + (100 * $diff / [double]$Baseline).ToString('F0', $invariant) + '%)' }
    $text
}

function Format-Num { param($Value, [int]$Decimals = 2) if ($null -eq $Value) { '-' } else { ([double]$Value).ToString("F$Decimals", $invariant) } }

if ($DotSourceForTest) { return }

if (-not $Run -or $Run.Count -eq 0) { throw "Pass at least one -Run 'label=path'." }
$styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
$fromUtc = if ($From) { [datetime]::Parse($From, $invariant, $styles) } else { $null }
$toUtc   = if ($To)   { [datetime]::Parse($To, $invariant, $styles) } else { $null }

$runs = foreach ($spec in $Run) {
    $at = $spec.IndexOf('=')
    if ($at -lt 1) { throw "-Run '$spec' is not label=path." }
    $label = $spec.Substring(0, $at); $path = $spec.Substring($at + 1)
    if (-not (Test-Path $path)) { throw "Run '$label': '$path' does not exist." }
    $files = if (Test-Path $path -PathType Container) { @(Get-ChildItem $path -Filter 'UmbracoTraceLog*.json' -File | Sort-Object Name) } else { @(Get-Item $path) }
    if ($files.Count -eq 0) { throw "Run '$label': no UmbracoTraceLog*.json in '$path'." }
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $files) {
        # The site may still hold the file open; read without locking it.
        $stream = [System.IO.FileStream]::new($file.FullName, 'Open', 'Read', 'ReadWrite')
        try { $reader = [System.IO.StreamReader]::new($stream); while ($null -ne ($l = $reader.ReadLine())) { if ($l.Contains('LoadTestHeartbeat cost')) { $lines.Add($l) } } } finally { $stream.Dispose() }
    }
    $cost = Get-RunCost -Lines $lines.ToArray() -SkipMinutes $SkipMinutes -From $fromUtc -To $toUtc
    if ($cost.Minutes -eq 0) { Write-Warning "Run '$label': no cost lines after skipping $SkipMinutes minute(s). Was it a Heartbeat run on a commit that records cost?" }
    [pscustomobject]@{ Label = $label; Cost = $cost }
}

$baseline = $runs[0]
$report = [System.Text.StringBuilder]::new()
[void]$report.AppendLine("# Cost per operation`n")
[void]$report.AppendLine("Baseline: **$($baseline.Label)**. $(if ($SkipMinutes) { "First $SkipMinutes minute(s) of each run left out. " })Kinds of request with fewer than $MinRequests requests are not shown.`n")

$measures = @(
    @{ Title = 'SQL commands per request'; Field = 'SqlCommands'; Decimals = 2 },
    @{ Title = 'SQL time per request (ms)'; Field = 'SqlMs'; Decimals = 2 },
    @{ Title = 'Time in the app per request (ms)'; Field = 'Ms'; Decimals = 2 }
)
$classNames = @($runs | ForEach-Object { $_.Cost.Classes } | Where-Object { $_.Requests -ge $MinRequests } | ForEach-Object { $_.Class } | Sort-Object -Unique)
foreach ($measure in $measures) {
    [void]$report.AppendLine("## $($measure.Title)`n")
    $header = '| Kind of request | ' + (($runs | ForEach-Object { $_.Label }) -join ' | ')
    $rule = '|---|' + ('---:|' * $runs.Count)
    if ($runs.Count -gt 1) { $header += ' | ' + (($runs | Select-Object -Skip 1 | ForEach-Object { "$($_.Label) vs $($baseline.Label)" }) -join ' | '); $rule += ('---:|' * ($runs.Count - 1)) }
    [void]$report.AppendLine($header + ' |'); [void]$report.AppendLine($rule)
    foreach ($class in $classNames) {
        $values = foreach ($r in $runs) { $c = $r.Cost.Classes | Where-Object Class -eq $class | Select-Object -First 1; if ($c -and $c.Requests -ge $MinRequests) { Get-PerRequest $c.($measure.Field) $c.Requests } else { $null } }
        $values = @($values)
        $row = "| $class | " + (($values | ForEach-Object { Format-Num $_ $measure.Decimals }) -join ' | ')
        if ($runs.Count -gt 1) { $row += ' | ' + ((1..($runs.Count - 1) | ForEach-Object { Format-CostChange $values[0] $values[$_] $measure.Decimals }) -join ' | ') }
        [void]$report.AppendLine($row + ' |')
    }
    [void]$report.AppendLine('')
}

[void]$report.AppendLine("## Whole process, per request`n")
[void]$report.AppendLine("All requests together, background work included, so compare runs with the same traffic mix.`n")
$header = '| Measure | ' + (($runs | ForEach-Object { $_.Label }) -join ' | ')
$rule = '|---|' + ('---:|' * $runs.Count)
if ($runs.Count -gt 1) { $header += ' | ' + (($runs | Select-Object -Skip 1 | ForEach-Object { "$($_.Label) vs $($baseline.Label)" }) -join ' | '); $rule += ('---:|' * ($runs.Count - 1)) }
[void]$report.AppendLine($header + ' |'); [void]$report.AppendLine($rule)
$processMeasures = @(
    @{ Title = 'Requests counted'; Value = { param($t) $t.Requests }; Decimals = 0; Change = $false },
    @{ Title = 'CPU per request (ms)'; Value = { param($t) Get-PerRequest $t.CpuMs $t.Requests }; Decimals = 2; Change = $true },
    @{ Title = 'Memory allocated per request (KB)'; Value = { param($t) Get-PerRequest ($t.AllocMb * 1024) $t.Requests }; Decimals = 0; Change = $true },
    @{ Title = 'Gen 0 collections per 1,000 requests'; Value = { param($t) Get-PerRequest ($t.Gen0 * 1000) $t.Requests }; Decimals = 1; Change = $true },
    @{ Title = 'Gen 2 collections per 1,000 requests'; Value = { param($t) Get-PerRequest ($t.Gen2 * 1000) $t.Requests }; Decimals = 2; Change = $true }
)
foreach ($pm in $processMeasures) {
    $values = @($runs | ForEach-Object { & $pm.Value $_.Cost.Total })
    $row = "| $($pm.Title) | " + (($values | ForEach-Object { Format-Num $_ $pm.Decimals }) -join ' | ')
    if ($runs.Count -gt 1) { $row += ' | ' + ((1..($runs.Count - 1) | ForEach-Object { if ($pm.Change) { Format-CostChange $values[0] $values[$_] $pm.Decimals } else { '' } }) -join ' | ') }
    [void]$report.AppendLine($row + ' |')
}

$text = $report.ToString()
Write-Host $text
if ($OutputPath) { $text | Out-File -FilePath $OutputPath -Encoding utf8 }

if ($OutCsv) {
    $rows = foreach ($r in $runs) {
        foreach ($c in $r.Cost.Classes) {
            [pscustomobject][ordered]@{
                run = $r.Label; kind = $c.Class; requests = $c.Requests
                sql_commands_per_request = (Format-Num (Get-PerRequest $c.SqlCommands $c.Requests) 4)
                sql_ms_per_request       = (Format-Num (Get-PerRequest $c.SqlMs $c.Requests) 4)
                commit_ms_per_request    = (Format-Num (Get-PerRequest $c.CommitMs $c.Requests) 4)
                app_ms_per_request       = (Format-Num (Get-PerRequest $c.Ms $c.Requests) 4)
                cpu_ms_per_request = ''; alloc_kb_per_request = ''; gen0_per_1000 = ''; gen2_per_1000 = ''
            }
        }
        $t = $r.Cost.Total
        [pscustomobject][ordered]@{
            run = $r.Label; kind = '(whole process)'; requests = $t.Requests
            sql_commands_per_request = ''; sql_ms_per_request = ''; commit_ms_per_request = ''; app_ms_per_request = ''
            cpu_ms_per_request   = (Format-Num (Get-PerRequest $t.CpuMs $t.Requests) 4)
            alloc_kb_per_request = (Format-Num (Get-PerRequest ($t.AllocMb * 1024) $t.Requests) 1)
            gen0_per_1000        = (Format-Num (Get-PerRequest ($t.Gen0 * 1000) $t.Requests) 2)
            gen2_per_1000        = (Format-Num (Get-PerRequest ($t.Gen2 * 1000) $t.Requests) 3)
        }
    }
    $rows | Export-Csv -Path $OutCsv -Encoding utf8
    Write-Host "Wrote $OutCsv"
}
