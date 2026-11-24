# Fast, dependency-free self-check for the pure parse/stats helpers whose
# failure mode is SILENTLY WRONG NUMBERS rather than a crash — a bad percentile
# or a mis-split CSV row doesn't error, it just publishes a wrong value to the
# dashboard after a ~15-minute paid pipeline run, where nobody notices.
#
# This is deliberately NOT a test framework and NOT coverage. It covers only the
# four functions that fail quietly: Get-Pct, Get-Median, Split-CsvLine, and the
# cellKey '__'-split invariant that four downstream scripts depend on, plus a
# small end-to-end Parse-JmeterCsv check (which exercises CSV quoting + the
# Transaction-Controller filter together).
#
# Fits the repo's "local self-check before queueing" approach — run it when you
# touch _helpers.ps1 or _history-helpers.ps1:
#   pwsh -File scripts/_selfcheck.ps1
# Exits 1 if any expectation fails, so it can gate a pre-queue check.

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/_history-helpers.ps1"   # dot-sources _helpers.ps1 too

$script:failures = 0
$script:checks   = 0

# Compare via string form so numeric-vs-string and element-type differences
# don't produce false failures, and so the same current-culture formatting is
# applied to both sides (a comma-decimal locale stringifies both the same way).
function Assert-Equal($Expected, $Actual, [string]$Label) {
    $script:checks++
    if ("$Expected" -ne "$Actual") {
        $script:failures++
        Write-Host "  FAIL  $Label : expected '$Expected', got '$Actual'" -ForegroundColor Red
    } else {
        Write-Host "  ok    $Label" -ForegroundColor DarkGray
    }
}

# Sequence compare — join with a sentinel that can't appear in our test data.
function Assert-Seq($Expected, $Actual, [string]$Label) {
    Assert-Equal ($Expected -join '|') ($Actual -join '|') $Label
}

Write-Host "Get-Pct (nearest-rank, ceil-based, 0-indexed)"
Assert-Equal 30 (Get-Pct @(10, 20, 30, 40, 50) 50)  "p50 of 5 values = 3rd value"
Assert-Equal 50 (Get-Pct @(10, 20, 30, 40, 50) 100) "p100 = max"
Assert-Equal 10 (Get-Pct @(10, 20, 30, 40, 50) 1)   "p1 = first value (i clamps to 0)"
Assert-Equal 5  (Get-Pct @(5) 99)                    "single sample: p99 = that sample"
Assert-Equal 5  (Get-Pct 5 99)                       "scalar (not array) single sample still works"
Assert-Equal 0  (Get-Pct @() 50)                     "empty input = 0"

Write-Host "Get-Median (mean of two middles for even N)"
Assert-Equal 2   (Get-Median @(1, 2, 3))    "odd N = middle"
Assert-Equal 2.5 (Get-Median @(1, 2, 3, 4)) "even N = mean of middles"
Assert-Equal 2.5 (Get-Median @(4, 1, 3, 2)) "unsorted input is sorted first"
Assert-Equal 5   (Get-Median @(5))          "single sample"
Assert-Equal 0   (Get-Median @())           "empty input = 0"

Write-Host "Select-LikeForLikeRuns (newest run's load decides which runs count)"
# Silent-wrong-numbers risk: a smoke or ramp run left in a cell shifts every
# median compare-runs.ps1 and show-trends.ps1 report, with nothing to flag it.
function New-LoadRow($Day, $Users, $Duration, $Methodology = 2) {
    [pscustomobject]@{ run_id = "r$Day"; run_started_at = "2026-11-${Day}T10:00:00Z"
        user_count = $Users; spawn_rate = 10; duration_seconds = $Duration; methodology_version = $Methodology }
}
$loadRows = @(
    (New-LoadRow '10' 20 60),       # older smoke run
    (New-LoadRow '13' 50 300),
    (New-LoadRow '11' 50 300),
    (New-LoadRow '12' 50 300 1),    # same load, older methodology
    (New-LoadRow '09' 50 300)
)
Assert-Seq @('r13', 'r11', 'r09') (@(Select-LikeForLikeRuns -Runs $loadRows) | ForEach-Object { $_.run_id }) "other loads and methodologies dropped, newest first"
Assert-Seq @('r13', 'r11')        (@(Select-LikeForLikeRuns -Runs $loadRows -First 2) | ForEach-Object { $_.run_id }) "-First caps after filtering"
Assert-Equal 0 @(Select-LikeForLikeRuns -Runs @()).Count "empty input = no runs"
Assert-Equal '50 VUs, spawn 10/s, 300 s, methodology 2' (Format-LoadKey (Get-LoadKey $loadRows[1])) "load key renders readably"

Write-Host "Select-LikeForLikeRuns (newest run's setup decides too: SKU, DTU cap, preset, seeder build)"
# Same silent risk as above: an override run (bigger SKU, higher DTU cap) or a
# run on another seeder build drove the same load on a different system, and
# without this it lands in the same median with nothing to flag it.
function New-SetupRow($Day, $Sku = 'P0v3', $Dtu = 20, $Seeder = '18.0.0-beta.1') {
    $r = New-LoadRow $Day 50 300
    $r | Add-Member app_service_sku $Sku
    $r | Add-Member pool_dtu_max $Dtu
    $r | Add-Member seeder_preset 'Medium'
    $r | Add-Member seeder_package_version $Seeder
    $r
}
$setupRows = @(
    (New-SetupRow '20'),
    (New-SetupRow '19' 'P3v3'),                       # appSkuOverride run
    (New-SetupRow '18' 'P0v3' 200),                   # poolDtuOverride run
    (New-SetupRow '17' 'P0v3' 20 '17.0.0-beta.2'),    # older seeder build
    (New-SetupRow '16'),
    (New-SetupRow '15')
)
Assert-Seq @('r20', 'r16', 'r15') (@(Select-LikeForLikeRuns -Runs $setupRows) | ForEach-Object { $_.run_id }) "override and other-seeder runs dropped"
Assert-Seq @('r20', 'r16')        (@(Select-LikeForLikeRuns -Runs $setupRows -First 2) | ForEach-Object { $_.run_id }) "-First counts only same-setup runs"
Assert-Equal 'SKU P0v3, 20 DTU, preset Medium, seeder 18.0.0-beta.1' (Format-SetupKey (Get-SetupKey $setupRows[0])) "setup key renders readably"
Assert-Equal 'SKU ,  DTU, preset , seeder build not recorded' (Format-SetupKey (Get-SetupKey $loadRows[1])) "rows without the setup fields read as their own bucket"
Assert-Equal 0 @(@($setupRows[0], $loadRows[1]) | Where-Object { (Get-ComparisonKey $_) -eq (Get-ComparisonKey $setupRows[0]) } | Select-Object -Skip 1).Count "a row without any setup fields never shares a median with one that has them"

# Rows from before seeder_package_version existed: taken as the build mapped
# for their major when the column was added, so a regression baseline survives
# the column's arrival - but only for that build, and only for known majors.
function New-LegacyRow($Version, $Seeder, $Started = '2026-11-14T10:00:00Z') {
    $r = New-SetupRow '14' 'P0v3' 20 $Seeder
    $r | Add-Member umbraco_version $Version
    $r.run_started_at = $Started
    $r
}
# Major 18 borrowed the v17 seeder until 05-09-2026 12:39 UTC.
Assert-Equal (Get-SetupKey (New-LegacyRow '18.1.0' '17.0.0-beta.2')) (Get-SetupKey (New-LegacyRow '18.1.0' '' '2026-08-20T10:00:00Z')) "an 18.x row from before 18 had its own seeder is taken as the borrowed v17 build"
Assert-Equal $false ((Get-SetupKey (New-LegacyRow '18.1.0' '18.0.0-beta.1')) -eq (Get-SetupKey (New-LegacyRow '18.1.0' '' '2026-08-20T10:00:00Z'))) "...so it never baselines a run on the v18 build"
Assert-Equal (Get-SetupKey (New-LegacyRow '17.2.0' '17.0.0-beta.2')) (Get-SetupKey (New-LegacyRow '17.2.0' '' '2026-08-20T10:00:00Z')) "a 17.x row is not affected by the v18 cut"
Assert-Equal '2026-11-22 09:00 Utc' ((ConvertTo-SinceUtc ([datetime]'2026-11-22T09:00:00')).ToString('yyyy-MM-dd HH:mm', [cultureinfo]::InvariantCulture) + ' ' + (ConvertTo-SinceUtc ([datetime]'2026-11-22T09:00:00')).Kind) "-Since with no zone is read as UTC"
Assert-Equal '2026-11-22 09:00 Utc' ((ConvertTo-SinceUtc ([datetime]'2026-11-22T09:00:00Z')).ToString('yyyy-MM-dd HH:mm', [cultureinfo]::InvariantCulture) + ' ' + (ConvertTo-SinceUtc ([datetime]'2026-11-22T09:00:00Z')).Kind) "-Since with a Z is the same instant, not the local clock time"
Assert-Equal (Get-SetupKey (New-LegacyRow '18.3.2' '18.0.0-beta.1')) (Get-SetupKey (New-LegacyRow '18.3.2' '')) "an 18.x row with no seeder build matches the build 18 used when the column was added"
Assert-Equal $false ((Get-SetupKey (New-LegacyRow '18.3.2' '18.0.0-beta.2')) -eq (Get-SetupKey (New-LegacyRow '18.3.2' ''))) "...and does not match a later seeder build"
Assert-Equal 'SKU P0v3, 20 DTU, preset Medium, seeder build not recorded' (Format-SetupKey (Get-SetupKey (New-LegacyRow '19.0.0-rc1' ''))) "a major with no legacy mapping keeps its own bucket"

Write-Host "Get-RunDate (always UTC, whatever the machine's time zone)"
# Silent-wrong-numbers risk: a run time shifted by the local offset moves the
# -Since cut, dropping (or admitting) runs near it with nothing to flag it.
$utc0930 = [datetime]::new(2026, 11, 20, 9, 30, 0, [DateTimeKind]::Utc)
foreach ($case in @(
    @{ Name = 'ISO string with Z';             Value = '2026-11-20T09:30:00Z' },
    @{ Name = 'string with an offset';         Value = '2026-11-20T10:30:00+01:00' },
    @{ Name = 'string with no zone';           Value = '2026-11-20 09:30:00' },
    @{ Name = 'DateTime from ConvertFrom-Json'; Value = ('{"t":"2026-11-20T09:30:00Z"}' | ConvertFrom-Json).t },
    @{ Name = 'local DateTime';                Value = $utc0930.ToLocalTime() }
)) {
    $d = Get-RunDate ([pscustomobject]@{ run_started_at = $case.Value })
    Assert-Equal "$($utc0930.Ticks)/Utc" "$($d.Ticks)/$($d.Kind)" "$($case.Name) -> 09:30 UTC"
}
Assert-Equal $true ($null -eq (Get-RunDate ([pscustomobject]@{ run_started_at = 'not a date' }))) "unparseable -> null, not a throw"

Write-Host "Split-ByErrorLimit (failing runs leave latency only, and are always reported)"
# Silent-wrong-numbers risk: instant failures are fast, so a failing run left
# in drags the latency median DOWN and makes the worse version look better.
function New-ErrRow($Id, $ErrorRate) { [pscustomobject]@{ run_id = $Id; error_rate = $ErrorRate; p95_ms = 100 } }
$errRows = @((New-ErrRow 'a' 0.0), (New-ErrRow 'b' 0.38), (New-ErrRow 'c' 0.05), (New-ErrRow 'd' 0.051))
$split = Split-ByErrorLimit -Runs $errRows -MaxErrorRate 5
Assert-Seq @('a', 'c') ($split.Latency | ForEach-Object { $_.run_id }) "runs at or under the limit keep their latency (5% is not over 5%)"
Assert-Seq @('b', 'd') ($split.Over    | ForEach-Object { $_.run_id }) "runs over the limit are returned, not dropped silently"
Assert-Equal $false $split.AllOver "some runs under the limit = not all over"
$off = Split-ByErrorLimit -Runs $errRows
Assert-Equal 4 @($off.Latency).Count "off by default: every run counts"
Assert-Equal 0 @($off.Over).Count    "off by default: nothing reported as over"
$allBad = Split-ByErrorLimit -Runs @((New-ErrRow 'x' 0.9), (New-ErrRow 'y' 1.0)) -MaxErrorRate 5
Assert-Equal $true $allBad.AllOver "every run over the limit is flagged"
Assert-Equal 2 @($allBad.Latency).Count "all over: falls back to all runs instead of an empty cell"
Assert-Equal $false (Split-ByErrorLimit -Runs @() -MaxErrorRate 5).AllOver "no runs = nothing to flag"

Write-Host "Split-CsvLine (RFC-4180 quoting)"
Assert-Seq @('a', 'b', 'c')      (Split-CsvLine 'a,b,c')        "plain fields"
Assert-Seq @('a', 'b,c', 'd')    (Split-CsvLine 'a,"b,c",d')    "quoted comma is not a delimiter"
Assert-Seq @('a', 'b"c', 'd')    (Split-CsvLine 'a,"b""c",d')   "doubled quote = literal quote"
Assert-Seq @('a', '', 'c')       (Split-CsvLine 'a,,c')         "empty field preserved"
Assert-Seq @('a', 'b', '')       (Split-CsvLine 'a,b,')         "trailing empty field preserved"

Write-Host "cellKey '__'-split invariant (-split '__', 3)"
# Four scripts (check-regression, compare-runs, show-trends, _history-helpers)
# rely on the limit-3 split so a sampler name that legally contains '__' keeps
# its trailing segment whole instead of spilling into a 4th element.
Assert-Seq @('17.0.0', 'Standard', 'Default') `
    ('17.0.0__Standard__Default' -split '__', 3) "3-field key splits cleanly"
Assert-Seq @('17.0.0', 'Standard', 'Backoffice__SavePublish') `
    ('17.0.0__Standard__Backoffice__SavePublish' -split '__', 3) "sampler name keeps embedded '__'"

Write-Host "Parse-JmeterCsv (CSV quoting + Transaction-Controller filter, end-to-end)"
$csv = @(
    'timeStamp,elapsed,label,responseCode,responseMessage,threadName,dataType,success,failureMessage'
    '1,100,Homepage,200,OK,t1,text,true,'
    # responseMessage has an embedded comma BEFORE the success column — without
    # correct quote handling the success flag would be read from the wrong field.
    '2,200,Homepage,500,"Server, Error",t1,text,false,boom'
    '3,150,01. Open Homepage,200,OK,t1,text,true,'   # Transaction Controller row
) -join "`n"
$tmp = New-TemporaryFile
try {
    Set-Content -LiteralPath $tmp.FullName -Value $csv -Encoding utf8

    # Default mode: drop TC rows, keep HTTP samplers.
    $r = Parse-JmeterCsv -Path $tmp.FullName -BuildAggregate
    Assert-Equal 1  $r.ByLabel.Keys.Count          "default mode: only the non-TC label kept"
    Assert-Equal $true ($r.ByLabel.ContainsKey('Homepage')) "default mode: 'Homepage' kept"
    Assert-Equal 2  $r.ByLabel['Homepage'].Samples.Count    "Homepage has 2 samples"
    Assert-Equal 1  $r.ByLabel['Homepage'].Errors           "1 error (quoted-comma row read success=false correctly)"
    Assert-Equal 2  $r.AllElapsed.Count                     "aggregate elapsed count"
    Assert-Equal 1  $r.TotalErrors                          "aggregate error count"

    # Inverted mode: keep only TC rows.
    $tc = Parse-JmeterCsv -Path $tmp.FullName -OnlyTransactionControllers
    Assert-Equal 1  $tc.ByLabel.Keys.Count                       "TC mode: only the TC label kept"
    Assert-Equal $true ($tc.ByLabel.ContainsKey('01. Open Homepage')) "TC mode: TC label kept"
    Assert-Equal 0  $tc.ByLabel['01. Open Homepage'].Errors      "TC row had success=true"

    # Observed sample window. publish-load-test-results.ps1 divides request
    # counts by this span instead of the CONFIGURED duration, so a wrong value
    # here silently mis-states requests_per_sec on every row.
    # Window is over KEPT rows only: default mode keeps timeStamps 1 and 2
    # (the TC row at 3 is filtered out), TC mode keeps only 3.
    Assert-Equal 1 $r.MinTimestamp  "default mode: min timeStamp over kept rows"
    Assert-Equal 2 $r.MaxTimestamp  "default mode: max timeStamp over kept rows"
    Assert-Equal 3 $tc.MinTimestamp "TC mode: window follows the filtered rows"
    Assert-Equal 3 $tc.MaxTimestamp "TC mode: single kept row = zero-width window"
}
finally {
    Remove-Item -LiteralPath $tmp.FullName -Force -ErrorAction SilentlyContinue
}

Write-Host "ConvertTo-DoubleOrNull (blank/malformed -> null, never 0)"
Assert-Equal 42.5 (ConvertTo-DoubleOrNull '42.5')          "parses a fractional value"
Assert-Equal 0    (ConvertTo-DoubleOrNull '0')             "literal '0' stays 0 (not null)"
Assert-Equal $true ($null -eq (ConvertTo-DoubleOrNull ''))  "empty -> null (not 0)"
Assert-Equal $true ($null -eq (ConvertTo-DoubleOrNull '  ')) "whitespace -> null"
Assert-Equal $true ($null -eq (ConvertTo-DoubleOrNull 'x')) "non-numeric -> null"
Assert-Equal 12.5 (ConvertTo-DoubleOrNull '12.5' )         "invariant culture: dot decimal parses"

Write-Host "ConvertTo-IntOrNull (blank/malformed -> null, never 0)"
Assert-Equal 512  (ConvertTo-IntOrNull '512')                       "parses a count"
Assert-Equal 0    (ConvertTo-IntOrNull '0')                         "literal '0' stays 0 (not null)"
Assert-Equal $true ($null -eq (ConvertTo-IntOrNull ''))             "empty -> null (not 0)"
Assert-Equal $true ($null -eq (ConvertTo-IntOrNull '12.5'))         "non-integer -> null"

Write-Host "ConvertTo-IsoUtc (normalize to ISO-8601 UTC; passthrough on bad input)"
Assert-Equal '2026-06-15T13:45:30.0000000Z' (ConvertTo-IsoUtc '2026-06-15T13:45:30.0000000Z') "already-ISO input is idempotent"
Assert-Equal ''          (ConvertTo-IsoUtc '')        "empty -> passthrough (no throw)"
Assert-Equal 'not-a-date' (ConvertTo-IsoUtc 'not-a-date') "malformed -> passthrough (no throw)"

Write-Host "Parse-JmeterCsv sample window with unparseable timestamps"
# Publishers must fall back to the configured duration rather than divide by a
# garbage span, so the no-usable-timestamp case has to surface as $null.
$csvNoTs = @(
    'timeStamp,elapsed,label,responseCode,responseMessage,threadName,dataType,success,failureMessage'
    ',100,Homepage,200,OK,t1,text,true,'
    'not-a-number,150,Homepage,200,OK,t1,text,true,'
) -join "`n"
$tmpNoTs = New-TemporaryFile
try {
    Set-Content -LiteralPath $tmpNoTs.FullName -Value $csvNoTs -Encoding utf8
    $rNoTs = Parse-JmeterCsv -Path $tmpNoTs.FullName
    Assert-Equal 2 $rNoTs.ByLabel['Homepage'].Samples.Count      "rows still parse without timestamps"
    Assert-Equal $true ($null -eq $rNoTs.MinTimestamp)           "no parseable timeStamp -> MinTimestamp null"
    Assert-Equal $true ($null -eq $rNoTs.MaxTimestamp)           "no parseable timeStamp -> MaxTimestamp null"
}
finally {
    Remove-Item -LiteralPath $tmpNoTs.FullName -Force -ErrorAction SilentlyContinue
}

Write-Host "Parse-JmeterCsv -RampCutoffMs (VU ramp-up exclusion)"
# Silent-wrong-numbers risk: a sentinel collision between "timestamp legitimately
# 0" and "timestamp failed to parse" would incorrectly let a should-be-excluded
# row survive - caught once already by direct testing, worth a durable check.
$csvRamp = @(
    'timeStamp,elapsed,label,responseCode,responseMessage,threadName,dataType,success,failureMessage'
    '0,100,Homepage,200,OK,t1,text,true,'
    '1000,100,Homepage,200,OK,t1,text,true,'
    '4000,100,Homepage,200,OK,t1,text,true,'
    '5000,100,Homepage,200,OK,t1,text,true,'
    '9000,100,Homepage,200,OK,t1,text,true,'
) -join "`n"
$tmpRamp = New-TemporaryFile
try {
    Set-Content -LiteralPath $tmpRamp.FullName -Value $csvRamp -Encoding utf8
    $rNoCutoff = Parse-JmeterCsv -Path $tmpRamp.FullName -RampCutoffMs 0
    Assert-Equal 5 $rNoCutoff.ByLabel['Homepage'].Samples.Count "cutoff disabled (0) -> every row kept"
    Assert-Equal 0 $rNoCutoff.MinTimestamp                      "cutoff disabled -> MinTimestamp includes a legitimate 0"

    $rCutoff = Parse-JmeterCsv -Path $tmpRamp.FullName -RampCutoffMs 5000
    Assert-Equal 2 $rCutoff.ByLabel['Homepage'].Samples.Count   "cutoff=5000 -> only t>=5000 rows kept (not t=0 via sentinel collision)"
    Assert-Equal 5000 $rCutoff.MinTimestamp                     "cutoff=5000 -> MinTimestamp reflects the surviving rows"

    $rAllExcluded = Parse-JmeterCsv -Path $tmpRamp.FullName -RampCutoffMs 99999
    Assert-Equal $false $rAllExcluded.ByLabel.ContainsKey('Homepage') "cutoff beyond all data -> bucket absent, not a stray t=0 row"
}
finally {
    Remove-Item -LiteralPath $tmpRamp.FullName -Force -ErrorAction SilentlyContinue
}

Write-Host "Parse-JmeterCsv -TimestampIsEnd (Locust files stamp the request's end)"
# A 9 s request that ENDED at 65 s started at 56 s: it belongs to the first
# minute and to a 60 s settle-in window, and reading the stamp as its start
# would put it in the second minute and keep it.
$csvEnd = @(
    'timeStamp,elapsed,label,responseCode,responseMessage,threadName,dataType,success,failureMessage'
    '10100,100,Homepage,200,OK,t1,text,true,'
    '65000,9000,Homepage,200,OK,t1,text,true,'
    '70050,50,Homepage,200,OK,t1,text,true,'
) -join "`n"
$tmpEnd = New-TemporaryFile
try {
    Set-Content -LiteralPath $tmpEnd.FullName -Value $csvEnd -Encoding utf8
    $rEnd = Parse-JmeterCsv -Path $tmpEnd.FullName -TimestampIsEnd -CollectPerMinute
    Assert-Equal 10000 $rEnd.MinTimestamp          "end stamps -> the window starts at the first request's start"
    Assert-Equal 70000 $rEnd.MaxTimestamp          "end stamps -> the window ends at the last request's start"
    Assert-Equal 2 $rEnd.ByMinute[[long]0].Count   "end stamps -> the 9 s request is bucketed in the minute it started in"
    $rEndCut = Parse-JmeterCsv -Path $tmpEnd.FullName -TimestampIsEnd -RampCutoffMs 60000
    Assert-Equal 1 $rEndCut.ByLabel['Homepage'].Samples.Count "end stamps -> a request started before the cutoff is excluded although it ended after it"
    $rStart = Parse-JmeterCsv -Path $tmpEnd.FullName -RampCutoffMs 60000
    Assert-Equal 2 $rStart.ByLabel['Homepage'].Samples.Count  "without the switch the stamp is still read as the start (JMeter files)"
}
finally {
    Remove-Item -LiteralPath $tmpEnd.FullName -Force -ErrorAction SilentlyContinue
}

Write-Host "Get-StallWindows (whole-site pauses)"
# 30 users, one request every 100 ms, each 20 ms - except a 10 s pause at
# t=60 s: everything started in [60 s, 62 s) is released at 70 s.
$stStart = New-Object 'System.Collections.Generic.List[long]'; $stElapsed = New-Object 'System.Collections.Generic.List[int]'
for ($ms = 0; $ms -lt 120000; $ms += 100) {
    if ($ms -ge 60000 -and $ms -lt 62000) { $stStart.Add($ms); $stElapsed.Add(70000 - $ms) }
    elseif ($ms -ge 62000 -and $ms -lt 70000) { continue }   # every user is stuck: nothing starts
    else { $stStart.Add($ms); $stElapsed.Add(20) }
}
$sw = Get-StallWindows -Start $stStart.ToArray() -Elapsed $stElapsed.ToArray()
Assert-Equal 1 $sw.Count          "one pause found"
Assert-Equal 10.0 $sw[0].Seconds  "pause length is first hung start to release"
Assert-Equal 20 $sw[0].Requests   "every request started in the pause is counted"

# One slow endpoint (a 7 s request every 2 s) among fast ones is not a pause.
$epStart = New-Object 'System.Collections.Generic.List[long]'; $epElapsed = New-Object 'System.Collections.Generic.List[int]'
for ($ms = 0; $ms -lt 120000; $ms += 100) { $epStart.Add($ms); $epElapsed.Add($(if ($ms % 2000 -eq 0) { 7000 } else { 20 })) }
Assert-Equal 0 (Get-StallWindows -Start $epStart.ToArray() -Elapsed $epElapsed.ToArray()).Count "a slow endpoint among fast requests is not a pause"
Assert-Equal 0 (Get-StallWindows -Start @() -Elapsed @()).Count "no samples -> no pauses"

Write-Host ""
Write-Host "Get-SlowSeconds (whole-site slow spells shorter than a pause)"
# The 10 s pause above: requests start in two of its seconds, all of them slow.
Assert-Equal 2 (Get-SlowSeconds -Start $stStart.ToArray() -Elapsed $stElapsed.ToArray()) "the seconds of a pause in which requests started are slow seconds"
# A 3 s spell where everything takes 1.5 s: no request reaches the 5 s a pause
# needs, so Get-StallWindows sees nothing; the three seconds are counted here.
$spStart = New-Object 'System.Collections.Generic.List[long]'; $spElapsed = New-Object 'System.Collections.Generic.List[int]'
for ($ms = 0; $ms -lt 60000; $ms += 100) { $spStart.Add($ms); $spElapsed.Add($(if ($ms -ge 30000 -and $ms -lt 33000) { 1500 } else { 20 })) }
Assert-Equal 0 (Get-StallWindows -Start $spStart.ToArray() -Elapsed $spElapsed.ToArray()).Count "a 3 s spell of 1.5 s requests is not a pause"
Assert-Equal 3 (Get-SlowSeconds -Start $spStart.ToArray() -Elapsed $spElapsed.ToArray())        "but its three seconds are slow seconds"
Assert-Equal 0 (Get-SlowSeconds -Start $epStart.ToArray() -Elapsed $epElapsed.ToArray())        "a slow endpoint among fast requests gives no slow seconds"
Assert-Equal 0 (Get-SlowSeconds -Start @() -Elapsed @())                                         "no samples -> no slow seconds"
# A second with too few requests cannot be judged.
Assert-Equal 0 (Get-SlowSeconds -Start ([long[]]@(1000, 1200, 1400)) -Elapsed ([int[]]@(2000, 2000, 2000))) "three slow requests in a second are too few to call it"

Write-Host ""
Write-Host "Get-SettleInSeconds (load driven before the measured window)"
Assert-Equal 300 (Get-SettleInSeconds -LoadProfile 'standard') "standard settles for 300 s"
Assert-Equal 300 (Get-SettleInSeconds -LoadProfile 'stress')   "stress settles for 300 s"
Assert-Equal 30  (Get-SettleInSeconds -LoadProfile 'smoke')    "smoke settles for 30 s"
Assert-Equal 0   (Get-SettleInSeconds -LoadProfile 'ramp')     "ramp measures the climb, no settle-in"
Assert-Equal 0   (Get-SettleInSeconds -LoadProfile 'standard' -Frontend $false) "JMeter runs have no settle-in"
Assert-Equal 0   (Get-SettleInSeconds -LoadProfile 'standard' -ColdStart $true) "a cold-start run measures from the first request"

Write-Host ""
Write-Host "Parse-JmeterCsv keeps failures out of the latency samples"
$okTmp = New-TemporaryFile
try {
    @(
        'timeStamp,elapsed,label,responseCode,responseMessage,threadName,dataType,success,failureMessage,bytes'
        '1000,10,Page,200,OK,u-1,text,TRUE,,4000'
        '2000,30,Page,200,OK,u-1,text,true,,2000'
        '3000,0,Page,0,empty bucket,u-1,text,FALSE,x,0'
        '4000,60000,Page,0,timeout,u-1,text,false,x,0'
    ) | Set-Content -Path $okTmp.FullName -Encoding utf8
    $ok = Parse-JmeterCsv -Path $okTmp.FullName
    Assert-Equal 4    $ok.ByLabel['Page'].Samples.Count   "every request is counted"
    Assert-Equal 2    $ok.ByLabel['Page'].Errors          "two failures"
    Assert-Equal 2    $ok.ByLabel['Page'].OkSamples.Count "latency samples are the successful ones"
    Assert-Equal 30   ($ok.ByLabel['Page'].OkSamples | Measure-Object -Maximum).Maximum "a 60 s timeout is not a latency sample"
    Assert-Equal 6000 $ok.ByLabel['Page'].OkBytes         "bytes summed over successful requests"
} finally { Remove-Item -LiteralPath $okTmp.FullName -Force -ErrorAction SilentlyContinue }

Write-Host ""
if ($script:failures -gt 0) {
    Write-Host "$($script:failures) of $($script:checks) checks FAILED." -ForegroundColor Red
    exit 1
}
Write-Host "All $($script:checks) checks passed." -ForegroundColor Green
# Explicit 0: falling off the end leaves $LASTEXITCODE unset in the caller, and
# a caller testing `-ne 0` then sees $null and reads success as failure.
exit 0
