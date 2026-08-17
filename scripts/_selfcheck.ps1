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

Write-Host "ConvertTo-IsoUtc (normalize to ISO-8601 UTC; passthrough on bad input)"
Assert-Equal '2026-06-15T13:45:30.0000000Z' (ConvertTo-IsoUtc '2026-06-15T13:45:30.0000000Z') "already-ISO input is idempotent"
Assert-Equal ''          (ConvertTo-IsoUtc '')        "empty -> passthrough (no throw)"
Assert-Equal 'not-a-date' (ConvertTo-IsoUtc 'not-a-date') "malformed -> passthrough (no throw)"

Write-Host ""
if ($script:failures -gt 0) {
    Write-Host "$($script:failures) of $($script:checks) checks FAILED." -ForegroundColor Red
    exit 1
}
Write-Host "All $($script:checks) checks passed." -ForegroundColor Green
