# Shared helpers; dot-source via `. "$PSScriptRoot/_helpers.ps1"`.

# Nearest-rank percentile (ceil-based, so p99 of N=100 is the 99th value, not max).
function Get-Pct ($Sorted, [double]$Pct) {
    if ($Sorted.Count -eq 0) { return 0 }
    $i = [int][math]::Ceiling($Sorted.Count * $Pct / 100.0) - 1
    if ($i -lt 0) { $i = 0 }
    if ($i -gt $Sorted.Count - 1) { $i = $Sorted.Count - 1 }
    return $Sorted[$i]
}

# Flat-container (package-base-address) roots of every feed the install script
# restores from, in the same order install-umbraco-cms-on-appservice.ps1 adds
# them: nuget.org, then the Umbraco prerelease and nightly MyGet feeds. Nightly
# tags (e.g. 18.2.0--rc.preview.84.g7df92f1) only ever exist on the last one,
# so a nuget.org-only check would reject versions that install fine.
$script:UmbracoPackageFlatContainerUrls = @(
    'https://api.nuget.org/v3-flatcontainer',
    'https://www.myget.org/F/umbracoprereleases/api/v3/flatcontainer',
    'https://www.myget.org/F/umbraconightly/api/v3/flatcontainer'
)

# True when $Version is a published version of $PackageId on any of the feeds
# (flat-container index: immediately consistent, unlike search). $PackageId is
# lowercased because the API requires it. A 404 (package id unknown on that
# feed) moves on to the next feed. An unreachable feed (DNS, timeout, 5xx) is
# warned about and skipped too - `dotnet new install` does the same (NU1801)
# and resolves from the remaining sources, so the gate shouldn't be stricter
# than the install it guards. Only when every feed is unreachable does this
# throw, since then nothing was actually checked.
function Test-NuGetPackageVersionExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$PackageId,
        [Parameter(Mandatory)] [string]$Version,
        [string[]]$FlatContainerUrls = $script:UmbracoPackageFlatContainerUrls
    )
    $unreachable = 0
    foreach ($root in $FlatContainerUrls) {
        $url = "$($root.TrimEnd('/'))/$($PackageId.ToLowerInvariant())/index.json"
        try {
            $index = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 30
        } catch {
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { continue }
            Write-Warning "Package feed $root is unreachable ($($_.Exception.Message)) - skipping it."
            $unreachable++
            continue
        }
        if (@($index.versions) -icontains $Version) { return $true }
    }
    if ($FlatContainerUrls.Count -gt 0 -and $unreachable -eq $FlatContainerUrls.Count) {
        throw "None of the $unreachable package feed(s) could be reached, so $PackageId $Version could not be checked."
    }
    return $false
}

function Get-LogAnalyticsWorkspaceCustomerId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspaceName,
        [Parameter(Mandatory)] [string]$ResourceGroupName
    )
    return az monitor log-analytics workspace show -n $WorkspaceName -g $ResourceGroupName --query customerId -o tsv
}

# Thin wrapper so every KQL-issuing script shares one az CLI invocation +
# JSON-decode shape. Callers still write their own KQL string.
function Invoke-LogAnalyticsQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspaceCustomerId,
        [Parameter(Mandatory)] [string]$Query
    )
    return @(az monitor log-analytics query -w $WorkspaceCustomerId --analytics-query $Query -o json | ConvertFrom-Json)
}

function Get-StorageAccountKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$StorageAccountName,
        [Parameter(Mandatory)] [string]$ResourceGroupName
    )
    $key = az storage account keys list `
        -n $StorageAccountName -g $ResourceGroupName `
        --query "[0].value" -o tsv
    if (-not $key) {
        Write-PipelineError "Could not read storage key for '$StorageAccountName' in '$ResourceGroupName' (requires Microsoft.Storage/storageAccounts/listKeys/action)."
    }
    return $key
}

# ##vso[task.logissue type=error] surfaces in the AzDO run summary; plain Write-Error doesn't.
function Write-PipelineError([string] $Message) {
    Write-Host "##vso[task.logissue type=error]$Message"
    exit 1
}

# Truncates to MaxLength, replacing the cut tail with a short hash so two
# values that only differ after the truncation point (e.g. two nightly builds
# sharing a long common version prefix) don't collapse into the same label.
# Used for fields with a hard external cap - e.g. AzureLoadTest@1's
# loadTestRunName (50 chars) - where the value embeds a long, variable-length
# Umbraco version tag that can't be bounded at the source.
function Get-BoundedLabel([string] $Value, [int] $MaxLength) {
    if ($Value.Length -le $MaxLength) { return $Value }
    $md5  = [System.Security.Cryptography.MD5]::Create()
    $hash = [System.BitConverter]::ToString($md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value))).Replace('-', '').Substring(0, 6).ToLowerInvariant()
    $keep = $MaxLength - $hash.Length - 1
    if ($keep -lt 1) { return $hash.Substring(0, $MaxLength) }
    # '-' rather than a more distinctive separator: the bounded value goes to
    # AzureLoadTest@1's run name/description, whose accepted charset isn't
    # documented, and a hyphen is already present in every one of these labels.
    return "$($Value.Substring(0, $keep))-$hash"
}

function Get-UmbracoMajor([string] $Version) {
    $raw = ($Version -split '\.')[0]
    $major = 0
    if (-not [int]::TryParse($raw, [ref]$major)) {
        Write-PipelineError "Cannot parse Umbraco major from '$Version' (expected X.Y.Z[-suffix])."
    }
    return $major
}

# Which loadtests/scenarios/<scenario>/jmeter/v<N>/ folder a major's backoffice
# run uses. v18 reuses the v17 plans (confirmed live). v19 is mapped the same
# way on the assumption its beta keeps the Management API routes those plans
# hit - NOT yet verified against a v19 deployment; if the warm-up route check in
# templates/load-test-job.yml reports drift on v19, copy jmeter/v17/ to
# jmeter/v19/ and fix the plans there instead of extending this list. Shared by
# resolve-run-config.ps1 (queue-time check) and generate-loadtest-config.ps1
# (the actual .jmx lookup) so the two can't drift when a major is added.
function Get-JmeterMajor([int] $UmbracoMajor) {
    if ($UmbracoMajor -in 18, 19) { return 17 }
    return $UmbracoMajor
}

# Normalize a datetime string to ISO-8601 UTC. Azure DevOps' $(System.PipelineStartTime)
# is space-separated ("2026-06-15 13:45:30+00:00"), which the Log Analytics Logs
# Ingestion API rejects on datetime columns with a 400. Round-tripping through
# DateTime gives the required ISO ("o") form. Idempotent on already-ISO input.
function ConvertTo-IsoUtc([string] $DateTime) {
    # TryParse, not Parse: empty/malformed input must not throw under
    # ErrorActionPreference=Stop — publish-load-test-results calls this before the
    # blob upload, and a throw here would lose the run entirely (the blob is the
    # source of truth). On unparseable input, return it unchanged; LA may reject
    # that one field, but the surrounding try/catch already tolerates that.
    $parsed = [datetime]::MinValue
    if ([string]::IsNullOrWhiteSpace($DateTime) -or
        -not [datetime]::TryParse($DateTime, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        return $DateTime
    }
    return $parsed.ToUniversalTime().ToString("o", [System.Globalization.CultureInfo]::InvariantCulture)
}

# Tolerant double parse: blank/malformed input -> $null (never 0). Callers that
# treat a missing metric as 0 would otherwise silently skew medians/comparisons.
# Invariant culture so a comma-decimal agent locale doesn't misread "42.5".
function ConvertTo-DoubleOrNull([string] $Value) {
    $d = 0.0
    if (-not [string]::IsNullOrWhiteSpace($Value) -and
        [double]::TryParse($Value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) {
        return $d
    }
    return $null
}

# Same contract for whole numbers (counts). This does NOT protect a caller from
# an unset pipeline variable: Azure DevOps leaves '$(someVariable)' in the
# script arguments as-is, and PowerShell evaluates that as a subexpression and
# fails before this function runs. The variable must be initialised (blank is
# fine) wherever the value is passed - see load-test-job.yml.
function ConvertTo-IntOrNull([string] $Value) {
    $i = 0
    if (-not [string]::IsNullOrWhiteSpace($Value) -and
        [int]::TryParse($Value, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$i)) {
        return $i
    }
    return $null
}

# Stream-parse one engine_results.csv (JMeter format). Memory-bounded: keeps
# per-task sample lists, not the whole CSV. Returns:
#   @{ ByLabel = @{ '<label>' = @{ Samples = List[int]; Errors = int } };
#      AllElapsed = List[int]    # only when -BuildAggregate
#      TotalErrors = int         # only when -BuildAggregate
#   }
# Split one CSV line into fields, honoring RFC-4180 double-quoting (a quoted
# field may contain commas; "" is a literal quote). JMeter quotes any field
# containing the delimiter, so responseMessage/failureMessage/URL values with
# commas would otherwise shift later columns and corrupt the success flag.
# Note: still assumes one sample per physical line — a quoted field containing
# a newline (rare; only some failureMessages) is not reassembled.
function Split-CsvLine ([string]$Line) {
    $fields = New-Object 'System.Collections.Generic.List[string]'
    $sb = New-Object System.Text.StringBuilder
    $inQuotes = $false
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $c = $Line[$i]
        if ($inQuotes) {
            if ($c -eq '"') {
                if ($i + 1 -lt $Line.Length -and $Line[$i + 1] -eq '"') { [void]$sb.Append('"'); $i++ }
                else { $inQuotes = $false }
            } else { [void]$sb.Append($c) }
        } else {
            if ($c -eq '"') { $inQuotes = $true }
            elseif ($c -eq ',') { $fields.Add($sb.ToString()); [void]$sb.Clear() }
            else { [void]$sb.Append($c) }
        }
    }
    $fields.Add($sb.ToString())
    return $fields
}

function Parse-JmeterCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [switch]$BuildAggregate,
        # Inverts the TC/sampler filter (see comment below). Default off keeps
        # the historical Locust/HTTP-sampler-only behaviour; backoffice (JMeter)
        # callers pass this to keep TC rows and drop the per-request rows.
        [switch]$OnlyTransactionControllers,
        # Epoch-ms cutoff excluding the VU ramp-up window from every stat (latency
        # samples, error counts, and the min/max timestamp span throughput is
        # derived from) - during ramp-up, load is below target so those samples
        # are systematically easier than steady-state and would understate p95/p99
        # if left in. 0 (default) disables the filter - the caller skips it
        # entirely for the 'ramp' profile, where the climb itself is the point.
        [long]$RampCutoffMs = 0,
        # The file's timeStamp is when the request ENDED, not when it started.
        # True for the files Azure Load Testing writes for Locust runs (checked on
        # run 305559: per user, consecutive requests are never closer than the
        # script's 1 s minimum wait only when read that way). The start is then
        # timeStamp - elapsed, and that is what the ramp cutoff, the sample window
        # and the per-minute buckets use. Not set for JMeter (.jmx) files.
        [switch]$TimestampIsEnd,
        # Also return every kept sample's start (epoch ms) and elapsed, as two
        # parallel lists, for Get-StallWindows.
        [switch]$CollectTimeline,
        # Also bucket the kept samples by the minute they started in (epoch ms of
        # the minute -> elapsed list), for the per-minute latency series. Off by
        # default: only the history publish needs it.
        [switch]$CollectPerMinute
    )

    $byLabel = @{}
    $allElapsed = if ($BuildAggregate) { New-Object 'System.Collections.Generic.List[int]' } else { $null }
    $byMinute   = if ($CollectPerMinute) { @{} } else { $null }
    $timelineStart   = if ($CollectTimeline) { New-Object 'System.Collections.Generic.List[long]' } else { $null }
    $timelineElapsed = if ($CollectTimeline) { New-Object 'System.Collections.Generic.List[int]' } else { $null }
    $totalErrors = 0
    # Sample window (JMeter timeStamp is epoch ms), so callers can derive
    # throughput from the span covered rather than the configured duration.
    # $null when no row carried a parseable timestamp.
    $minTs = [long]::MaxValue
    $maxTs = [long]::MinValue

    # JMeter Transaction Controllers with parent="true" emit a parent-transaction
    # row in the CSV in addition to the HTTP-sampler row for each request.
    # Heuristic: TC labels in our .jmx files follow a "NN. Description" pattern
    # (e.g. "01. Open Homepage"). Locust samplers use plain names ("Homepage",
    # "Detail") that won't match. Adjust if naming conventions change.
    #
    # Default mode (Locust / legacy backoffice): drop TC rows and keep the
    # HTTP-sampler rows. Rationale: the TC parent row's success/fail flag can
    # diverge from the child's (we've seen TCs report ~100% failure while every
    # child HTTP request returned 200 OK, likely due to redirect-chain
    # accounting on the parent), so the HTTP-sampler row is the more reliable
    # source of latency + success when both exist.
    #
    # -OnlyTransactionControllers mode (backoffice JMeter runs): invert the
    # filter — keep TC rows and drop the per-HTTP-request rows. Backoffice
    # .jmx files are organised as "01. <step>", "02. <step>", … sequences;
    # showing every underlying GET/POST in the workbook clutters the sampler
    # picker with dozens of low-signal rows per .jmx. The TC row is the unit
    # of business-meaningful work for those tests. Trade-off: the success/fail
    # caveat above now drives error_rate for backoffice runs; revisit by
    # deriving TC success from child rows if it becomes a false-positive issue.
    $tcLabelPattern = '^\d+\.\s+'

    $reader = [System.IO.StreamReader]::new($Path)
    try {
        # Resolve columns by header name rather than fixed position — JMeter
        # column order is configurable. Fall back to the conventional indices
        # (elapsed=1, label=2, success=7) if a header field is missing.
        $headerLine = $reader.ReadLine()
        $idxTimestamp = 0; $idxElapsed = 1; $idxLabel = 2; $idxSuccess = 7; $idxBytes = -1
        if ($headerLine) {
            $header = Split-CsvLine $headerLine
            for ($h = 0; $h -lt $header.Count; $h++) {
                switch ($header[$h]) {
                    'timeStamp' { $idxTimestamp = $h }
                    'elapsed'   { $idxElapsed   = $h }
                    'label'     { $idxLabel     = $h }
                    'success'   { $idxSuccess   = $h }
                    'bytes'     { $idxBytes     = $h }
                }
            }
        }
        $minCols = [Math]::Max($idxSuccess, [Math]::Max($idxElapsed, [Math]::Max($idxLabel, $idxTimestamp))) + 1
        while ($null -ne ($line = $reader.ReadLine())) {
            $cols = Split-CsvLine $line
            if ($cols.Count -lt $minCols) { continue }

            # Checked first so a ramp-window row is excluded from every stat below,
            # not just the ones computed after it. $tsOk (not "$ts -gt 0") gates
            # this - epoch-ms timestamps are never legitimately 0 in practice, but
            # using the parse-success flag rather than overloading 0 as a sentinel
            # avoids a real off-by-one if a test/edge-case value ever is 0. A row
            # with an unparseable timestamp can't be judged against the cutoff, so
            # it's let through rather than dropped - same tolerant posture as the
            # min/max tracking a few lines down.
            $elapsed = 0
            if (-not [int]::TryParse($cols[$idxElapsed], [ref]$elapsed)) { continue }
            # $ts is the request's START from here on.
            $ts = [long]0
            $tsOk = [long]::TryParse($cols[$idxTimestamp], [ref]$ts)
            if ($tsOk -and $TimestampIsEnd) { $ts -= $elapsed }
            if ($RampCutoffMs -gt 0 -and $tsOk -and $ts -lt $RampCutoffMs) { continue }
            $label   = $cols[$idxLabel]
            if ($OnlyTransactionControllers) {
                if ($label -notmatch $tcLabelPattern) { continue }
            } else {
                if ($label -match $tcLabelPattern) { continue }
            }
            $success = $cols[$idxSuccess] -ieq 'true'

            $bucket = $byLabel[$label]
            if (-not $bucket) {
                $bucket = @{
                    Samples   = (New-Object 'System.Collections.Generic.List[int]')
                    # The successful ones only: what latency statistics are
                    # taken over. A failure is fast (an instant 5xx, an empty
                    # URL bucket at 0 ms) or a timeout, and either way says
                    # nothing about how long a served page takes.
                    OkSamples = (New-Object 'System.Collections.Generic.List[int]')
                    Errors    = 0
                    # Response bytes of the successful samples (0 when the
                    # file has no 'bytes' column).
                    OkBytes   = [long]0
                }
                $byLabel[$label] = $bucket
            }
            $bucket.Samples.Add($elapsed)
            if ($success) {
                $bucket.OkSamples.Add($elapsed)
                $bytes = [long]0
                if ($idxBytes -ge 0 -and $idxBytes -lt $cols.Count -and [long]::TryParse($cols[$idxBytes], [ref]$bytes)) { $bucket.OkBytes += $bytes }
            } else { $bucket.Errors++ }

            # Post-filter, so the span matches the samples the metrics come from.
            if ($tsOk) {
                if ($ts -lt $minTs) { $minTs = $ts }
                if ($ts -gt $maxTs) { $maxTs = $ts }
                if ($CollectTimeline) { $timelineStart.Add($ts); $timelineElapsed.Add($elapsed) }
                if ($CollectPerMinute) {
                    $minute = $ts - ($ts % 60000)
                    $minuteSamples = $byMinute[$minute]
                    if ($null -eq $minuteSamples) {
                        $minuteSamples = New-Object 'System.Collections.Generic.List[int]'
                        $byMinute[$minute] = $minuteSamples
                    }
                    $minuteSamples.Add($elapsed)
                }
            }

            if ($BuildAggregate) {
                $allElapsed.Add($elapsed)
                if (-not $success) { $totalErrors++ }
            }
        }
    } finally { $reader.Dispose() }

    return @{
        ByLabel      = $byLabel
        AllElapsed   = $allElapsed
        TotalErrors  = $totalErrors
        ByMinute     = $byMinute
        TimelineStart   = $timelineStart
        TimelineElapsed = $timelineElapsed
        MinTimestamp = if ($minTs -eq [long]::MaxValue) { $null } else { $minTs }
        MaxTimestamp = if ($maxTs -eq [long]::MinValue) { $null } else { $maxTs }
    }
}

# Whole-site pauses in a run: stretches where the site answered (almost)
# nothing, as opposed to one slow page. Seen on run 305559 (Standard): three
# times, every request started over ~10 s hung and all were released within
# the same second, which put p99 at 8-9 s while p95 stayed under 350 ms.
# A candidate window is the merged span of requests that took >= $StallMs. It
# counts as a pause only if nearly everything that started inside it was slow
# too (>= $SlowShare of >= $MinRequests requests took >= $FastMs): one slow
# endpoint among fast ones leaves the fast ones in the window and is not a
# pause. The last $FastMs of a window is left out of that test - a request
# started just before the release is legitimately quick.
# $Start (epoch ms) and $Elapsed are Parse-JmeterCsv -CollectTimeline's lists.
function Get-StallWindows {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [long[]]$Start,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [int[]]$Elapsed,
        [int]$StallMs = 5000,
        [int]$FastMs = 1000,
        [int]$MinRequests = 10,
        [double]$SlowShare = 0.9
    )
    $windows = New-Object System.Collections.Generic.List[object]
    if ($Start.Count -eq 0) { return , $windows }
    $order = [int[]](0..($Start.Count - 1))
    [array]::Sort([long[]]$Start.Clone(), $order)

    # Merge the slow requests' [start, end] spans, in start order.
    $candidates = New-Object System.Collections.Generic.List[object]
    $curStart = [long]-1; $curEnd = [long]-1
    foreach ($i in $order) {
        if ($Elapsed[$i] -lt $StallMs) { continue }
        $s = $Start[$i]; $e = $s + $Elapsed[$i]
        if ($curEnd -ge 0 -and $s -le $curEnd) { if ($e -gt $curEnd) { $curEnd = $e } }
        else {
            if ($curEnd -ge 0) { $candidates.Add(@($curStart, $curEnd)) }
            $curStart = $s; $curEnd = $e
        }
    }
    if ($curEnd -ge 0) { $candidates.Add(@($curStart, $curEnd)) }

    foreach ($c in $candidates) {
        $wStart = [long]$c[0]; $wEnd = [long]$c[1]
        $n = 0; $slow = 0
        foreach ($i in $order) {
            $s = $Start[$i]
            if ($s -lt $wStart) { continue }
            if ($s -ge $wEnd - $FastMs) { break }
            $n++
            if ($Elapsed[$i] -ge $FastMs) { $slow++ }
        }
        if ($n -ge $MinRequests -and ($slow / [double]$n) -ge $SlowShare) {
            $windows.Add([pscustomobject]@{ StartMs = $wStart; EndMs = $wEnd; Seconds = [math]::Round(($wEnd - $wStart) / 1000.0, 1); Requests = $n })
        }
    }
    return , $windows
}

# Seconds of load driven BEFORE the measured window of a frontend (Locust) run.
# The load test runs for settle-in + duration; only requests that start after
# the settle-in count. A site that was started a minute or two before the load
# is still compiling and filling caches under traffic for several minutes: on
# eleven Starter runs the share of slow reads halved between the first and the
# fourth minute, and with only the first 60 s left out the same two builds
# compared 40% apart or level depending on that cutoff alone. One place, used
# by generate-loadtest-config.ps1 (how long to run) and
# publish-load-test-results.ps1 (what to leave out), so the two cannot drift.
# JMeter (backoffice) runs have no settle-in; the ramp profile measures the
# climb itself; and a cold-start run (skipWarmup) exists to measure exactly
# the period a settle-in would throw away.
function Get-SettleInSeconds {
    param([string]$LoadProfile, [bool]$Frontend = $true, [bool]$ColdStart = $false)
    if (-not $Frontend -or $ColdStart) { return 0 }
    switch ($LoadProfile) {
        'ramp'  { return 0 }
        'smoke' { return 30 }
        default { return 300 }
    }
}

# Seconds of the run in which the site as a whole was slow: at least
# $MinRequests requests started in that second and at least $SlowShare of them
# took $SlowMs or longer. Complements Get-StallWindows, which only counts
# stretches containing a request of 5 s or more and therefore misses the 1-4 s
# spells most Starter and Standard runs have (build 305703 Starter: nine such
# seconds, published with zero pauses). Counted per second, so one unrelated
# slow request cannot stretch or hide a spell.
# $Start (epoch ms) and $Elapsed are Parse-JmeterCsv -CollectTimeline's lists.
function Get-SlowSeconds {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [long[]]$Start,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [int[]]$Elapsed,
        [int]$SlowMs = 1000,
        [int]$MinRequests = 5,
        [double]$SlowShare = 0.9
    )
    $started = @{}
    $slow    = @{}
    for ($i = 0; $i -lt $Start.Count; $i++) {
        $second = [long][math]::Floor($Start[$i] / 1000.0)
        $started[$second] = 1 + [int]$started[$second]
        if ($Elapsed[$i] -ge $SlowMs) { $slow[$second] = 1 + [int]$slow[$second] }
    }
    $count = 0
    foreach ($second in $started.Keys) {
        $n = [int]$started[$second]
        if ($n -ge $MinRequests -and ([int]$slow[$second] / [double]$n) -ge $SlowShare) { $count++ }
    }
    return $count
}

# Per-minute client-side latency across all samplers, as LoadTestSeries_CL
# points (same shape as the Azure Monitor series): latency_p50_ms,
# latency_p95_ms and latency_max_ms per minute. Shows WHEN slow requests
# happened - a run-wide stall (every sampler capped at the same max) shows as
# a spike in one or two minutes, a uniformly slower build as a raised line.
# $ByMinute is Parse-JmeterCsv -CollectPerMinute's ByMinute, merged across
# engine files. The first and last minute are usually partial.
function Get-PerMinuteLatencyPoints {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [hashtable]$ByMinute)
    $points = New-Object System.Collections.Generic.List[object]
    foreach ($minute in ($ByMinute.Keys | Sort-Object)) {
        $sorted = [System.Collections.Generic.List[int]]::new($ByMinute[$minute])
        if ($sorted.Count -eq 0) { continue }
        $sorted.Sort()
        $time = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$minute).UtcDateTime.ToString('o')
        foreach ($stat in @(
                @{ Name = 'latency_p50_ms'; Value = (Get-Pct $sorted 50) },
                @{ Name = 'latency_p95_ms'; Value = (Get-Pct $sorted 95) },
                @{ Name = 'latency_max_ms'; Value = $sorted[$sorted.Count - 1] })) {
            $points.Add([pscustomobject]@{
                TimeGenerated = $time
                metric_name   = $stat.Name
                value         = [double]$stat.Value
            })
        }
    }
    return $points
}
