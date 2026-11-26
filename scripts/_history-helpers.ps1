# Shared helpers for scripts that read summary.ndjson rows out of history storage.
# Dot-source from a script:
#   . "$PSScriptRoot/_history-helpers.ps1"
# Then call Get-HistoryCells / Get-Median / Get-HistoryPrefix / Select-LikeForLikeRuns.
#
# The leading underscore signals "internal helper, not a top-level CLI" so it
# stands apart in directory listings. Generic helpers (storage key, percentile,
# error exit) live in _helpers.ps1 — pulled in here so callers only have to
# dot-source one file.

. "$PSScriptRoot/_helpers.ps1"

function Get-HistoryPrefix {
    param (
        [Parameter(Mandatory = $true)] [string]$Scenario,
        [string]$Major
    )
    if ($Major) { "$Scenario/$Major/" } else { "$Scenario/" }
}

# Parse a row's run_started_at into a DateTime, returning $null on failure.
# Used by every consumer of Get-HistoryCells to sort/filter by run time
# defensively — a single corrupt timestamp in history must not throw under
# $ErrorActionPreference="Stop" and brick the whole analysis script.
# _history-helpers tolerates bad JSON lines at load-time; this closes the
# equivalent gap for parse-after-load.
#
# Always returns UTC. ConvertFrom-Json has usually turned the value into a
# DateTime already; casting that back to a string drops the zone, and parsing
# the result gave Kind=Unspecified, which a later ToUniversalTime() shifted by
# the local offset - -Since then cut an hour off on a UTC+1 machine. A value
# with no zone at all is taken as UTC, which is what the pipeline writes.
function Get-RunDate {
    param([Parameter(Mandatory)] $Row)
    try {
        $value = $Row.run_started_at
        if ($value -is [datetime]) {
            if ($value.Kind -eq [DateTimeKind]::Unspecified) { return [datetime]::SpecifyKind($value, [DateTimeKind]::Utc) }
            return $value.ToUniversalTime()
        }
        if ($value -is [DateTimeOffset]) { return $value.UtcDateTime }
        $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
        return [datetime]::Parse([string]$value, [System.Globalization.CultureInfo]::InvariantCulture, $styles)
    } catch {
        return $null
    }
}

# Plan name from a bare sampler label ("Login / 01. step" -> "Login").
# Frontend samplers carry no " / " step suffix, hence the fallback.
function Get-PlanName([string] $Sampler) {
    if ($Sampler -match '^(.+?) / ') { return $Matches[1] }
    return '(frontend)'
}

# Median of a numeric array — used by both the trend renderer and the regression
# gate. For even N, returns the mean of the two middle values.
function Get-Median([double[]] $values) {
    $sorted = @($values | Sort-Object)
    $n = $sorted.Count
    if ($n -eq 0) { return 0 }
    if ($n % 2 -eq 1) { return $sorted[[int](($n - 1) / 2)] }
    return ($sorted[[int]($n / 2 - 1)] + $sorted[[int]($n / 2)]) / 2
}

# Population stddev (divides by N): we're describing the spread of the K runs
# we have, not estimating a population from a sample. Bessel-corrected sample
# stddev would over-inflate the visible spread when N is small (3-5 runs).
function Get-PopulationStdDev([double[]] $values) {
    $n = $values.Count
    if ($n -le 1) { return 0 }
    $mean = ($values | Measure-Object -Average).Average
    $sumSq = 0.0
    foreach ($v in $values) { $sumSq += [math]::Pow($v - $mean, 2) }
    return [math]::Sqrt($sumSq / $n)
}

# What makes two rows of one cell comparable: the load actually driven (VU
# count, spawn rate, duration) and how the published stats were computed.
# Profile isn't a stored column, so this matches the published load params,
# which every metric row carries. Rows from before methodology_version existed
# read as "" and form their own bucket.
function Get-LoadKey {
    param([Parameter(Mandatory)] $Row)
    "$($Row.user_count)|$($Row.spawn_rate)|$($Row.duration_seconds)|$($Row.methodology_version)"
}

# The -Since cut as Get-HistoryCells applies it: UTC. A value with no zone is
# read as UTC (same cut on a laptop and on the build agent); one given with an
# offset or a Z is bound by PowerShell as local time and converted back.
function ConvertTo-SinceUtc([datetime] $Since) {
    if ($Since.Kind -eq [DateTimeKind]::Unspecified) { return [datetime]::SpecifyKind($Since, [DateTimeKind]::Utc) }
    $Since.ToUniversalTime()
}

# Human-readable form of a Get-LoadKey value, for report headers and warnings.
function Format-LoadKey([string] $LoadKey) {
    $p = $LoadKey -split '\|'
    $methodology = if ($p.Count -gt 3 -and $p[3]) { "methodology $($p[3])" } else { 'methodology unversioned' }
    "$($p[0]) VUs, spawn $($p[1])/s, $($p[2]) s, $methodology"
}

# What the run was measured ON, as opposed to the load it drove: the App
# Service SKU, the per-DB DTU cap, the seeder preset and the seeder package
# build. The queue-time overrides change the first three without changing a
# run's cell or its load key, and each Umbraco major has used more than one
# seeder build over time - a run on different hardware or different content is
# a different test, so it must not share a median with the others.
#
# Rows published before seeder_package_version existed read as "" there. They
# are taken to have used the build that was mapped for their major when the
# column was added ($LegacySeederBuilds), so the first run that records its
# build still has its older runs as a regression baseline instead of starting
# from "insufficient baseline". This is an ASSUMPTION about those rows, not a
# recorded fact, and the table is frozen on purpose: it must not follow
# seeder-versions.json, or a later seeder bump would make the old rows match
# the new build. A major not listed here keeps "" and forms its own bucket.
#
# Major 18 borrowed the v17 build until commit d30c0e0 (05-09-2026 12:39 UTC)
# pointed it at its own, so its unrecorded rows are split at that moment. The
# cut is the commit time, the closest thing on record; a run queued from a
# branch that had not picked the commit up yet would land on the wrong side.
$script:LegacySeederBuilds = @{
    '13' = '13.0.0-beta.1'
    '17' = '17.0.0-beta.2'
    '18' = '18.0.0-beta.1'
}
$script:Legacy18OwnSeederFrom = [datetime]::new(2026, 9, 5, 12, 39, 45, [DateTimeKind]::Utc)
function Get-SetupKey {
    param([Parameter(Mandatory)] $Row)
    $seeder = [string]$Row.seeder_package_version
    if (-not $seeder) {
        $major = ([string]$Row.umbraco_version -split '\.')[0]
        if ($major -and $script:LegacySeederBuilds.ContainsKey($major)) { $seeder = $script:LegacySeederBuilds[$major] }
        if ($major -eq '18') {
            $started = Get-RunDate $Row
            if ($null -eq $started -or $started -lt $script:Legacy18OwnSeederFrom) { $seeder = $script:LegacySeederBuilds['17'] }
        }
    }
    "$($Row.app_service_sku)|$($Row.pool_dtu_max)|$($Row.seeder_preset)|$seeder"
}

function Format-SetupKey([string] $SetupKey) {
    $p = $SetupKey -split '\|'
    $seeder = if ($p.Count -gt 3 -and $p[3]) { "seeder $($p[3])" } else { 'seeder build not recorded' }
    "SKU $($p[0]), $($p[1]) DTU, preset $($p[2]), $seeder"
}

# The full "same conditions" key a median or a regression baseline groups by:
# same load, same methodology, same setup.
function Get-ComparisonKey {
    param([Parameter(Mandatory)] $Row)
    "$(Get-LoadKey $Row)#$(Get-SetupKey $Row)"
}

# Newest-first runs of one cell that drove the same load as the newest run,
# optionally capped at -First. Aggregating a cell without this folds a smoke or
# ramp run into the same median as the standard runs around it. The newest run
# decides which load counts, mirroring check-regression.ps1, where the
# candidate does. Callers should wrap the result in @().
function Select-LikeForLikeRuns {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Runs,
        [int]$First = 0
    )
    # Rows whose run_started_at doesn't parse can't be placed in time, so they
    # can neither decide which load is newest nor take a slot in the window -
    # check-regression.ps1 drops them the same way. They are only used when the
    # cell has nothing else.
    $dated  = @($Runs | Where-Object { $null -ne (Get-RunDate $_) })
    $usable = if ($dated.Count -gt 0) { $dated } else { @($Runs) }
    $sorted = @($usable | Sort-Object { Get-RunDate $_ } -Descending)
    if ($sorted.Count -eq 0) { return }
    # Load AND setup (Get-ComparisonKey): a run on an overridden SKU/DTU cap or
    # another seeder build drove the same load on different conditions, and
    # folding it in would move the median with nothing in the report to say so.
    $key  = Get-ComparisonKey $sorted[0]
    $same = @($sorted | Where-Object { (Get-ComparisonKey $_) -eq $key })
    if ($First -gt 0) { $same = @($same | Select-Object -First $First) }
    $same
}

# Splits one cell's picked runs by an error-rate limit (percent; negative =
# off). Rows over the limit leave the LATENCY statistics only: an instant
# failure is fast, so it drags p50/p95 down and flatters the version. They
# stay in the error rate and request counts, so a version that fails is still
# reported as failing - callers must name what they leave out.
#   Latency  - the runs latency figures should be computed over
#   Over     - the runs that went over the limit
#   AllOver  - every run went over it: there is no clean latency, so Latency
#              falls back to all runs rather than leaving the cell empty, and
#              the caller flags it (the errors are the finding there)
function Split-ByErrorLimit {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Runs,
        [double]$MaxErrorRate = -1
    )
    if ($MaxErrorRate -lt 0) {
        return [pscustomobject]@{ Latency = @($Runs); Over = @(); AllOver = $false }
    }
    # Rounded before comparing: 0.07 * 100 is 7.000000000000001 in floating
    # point, which put a run at exactly the limit over it.
    $ok   = @($Runs | Where-Object { [math]::Round([double]$_.error_rate * 100, 6) -le $MaxErrorRate })
    $over = @($Runs | Where-Object { [math]::Round([double]$_.error_rate * 100, 6) -gt $MaxErrorRate })
    $allOver = $Runs.Count -gt 0 -and $ok.Count -eq 0
    [pscustomobject]@{ Latency = $(if ($allOver) { @($Runs) } else { $ok }); Over = $over; AllOver = $allOver }
}

# Loads every summary.ndjson under the scenario prefix and returns a hashtable
# keyed by '{umbraco_version}__{infra_tier}__{scenario_name}' -> list of NDJSON
# rows for that cell. Optional -Sampler filters rows to a single Locust task.
#
# Skips metadata-only NDJSON rows (no scenario_name = no metrics) and silently
# skips lines that aren't valid JSON, so partially-corrupt files don't break a
# full-history scan.
function Get-HistoryCells {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)] [string]$Scenario,
        [Parameter(Mandatory = $true)] [string]$HistoryResourceGroup,
        [Parameter(Mandatory = $true)] [string]$StorageAccountName,
        [Parameter(Mandatory = $true)] [string]$ContainerName,
        [string]$Major,
        [string]$Sampler,

        # When both are set, every row whose run_id matches -RunId is recorded into
        # AttemptedVersionTiers.Value as "version__tier" -> $true, BEFORE any of the
        # ok/cold_start/scenario_name filters below run. A tier that fails completely
        # (e.g. its .jmx never produced engine_results.csv) still gets a metadata-only
        # placeholder row published to history — no scenario_name, parse_status
        # "no_metrics" — which the filters below correctly exclude from $cells but
        # which still proves the run attempted that tier. Without this, a caller has
        # no way to tell "this run attempted this tier and it totally failed" apart
        # from "this run never touched this tier" — $cells alone can't make that
        # distinction, since a fully-failed tier has zero ok rows either way.
        [string]$RunId,
        [ref]$AttemptedVersionTiers,
        # Same bookkeeping one level down, for backoffice: "version__tier__plan"
        # for every row of -RunId that names a jmeter_test_name, placeholder
        # rows included. Lets a caller tell a plan that ran and published
        # nothing from one that was never queued.
        [ref]$AttemptedPlans,

        # Optional scope for "these runs exactly": only rows whose run_id is in
        # -OnlyRunIds and/or that started at or after -Since count. Applied after
        # the attempted-tier bookkeeping above, so it never hides a failure.
        [string[]]$OnlyRunIds,
        [Nullable[datetime]]$Since,
        # Runs known to be invalid, dropped entirely (same placement as above).
        [string[]]$ExcludeRunIds
    )
    $OnlyRunIds    = @($OnlyRunIds    | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim().TrimStart('#') } | Where-Object { $_ })
    $ExcludeRunIds = @($ExcludeRunIds | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim().TrimStart('#') } | Where-Object { $_ })

    $prefix = Get-HistoryPrefix -Scenario $Scenario -Major $Major

    $storageKey = Get-StorageAccountKey -StorageAccountName $StorageAccountName -ResourceGroupName $HistoryResourceGroup

    # --num-results '*': the default stops at 5000 blobs, counted BEFORE the
    # --query filter runs client-side, and the raw artifacts share the prefix.
    # Past that the listing is cut silently, newest major last.
    Write-Host "Listing blobs under $prefix..."
    $listJson = az storage blob list `
        --account-name $StorageAccountName --account-key $storageKey `
        --container-name $ContainerName `
        --prefix $prefix `
        --num-results '*' `
        --query "[?ends_with(name, 'summary.ndjson')].name" `
        -o json

    $blobNames = @($listJson | ConvertFrom-Json)
    if ($blobNames.Count -eq 0) {
        Write-Warning "No summary.ndjson found under '$prefix' in $StorageAccountName/$ContainerName."
        return @{}
    }
    Write-Host "Found $($blobNames.Count) summary file(s)."

    $cells = @{}
    foreach ($blob in $blobNames) {
        $tmp = New-TemporaryFile
        az storage blob download `
            --account-name $StorageAccountName --account-key $storageKey `
            --container-name $ContainerName `
            --name $blob `
            --file $tmp.FullName `
            --no-progress | Out-Null

        $lines = Get-Content -Path $tmp.FullName
        Remove-Item -LiteralPath $tmp.FullName -Force -ErrorAction SilentlyContinue

        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $row = $line | ConvertFrom-Json } catch { continue }
            if ($AttemptedVersionTiers -and $RunId -and [string]$row.run_id -eq $RunId -and $row.umbraco_version -and $row.infra_tier) {
                $AttemptedVersionTiers.Value["$($row.umbraco_version)__$($row.infra_tier)"] = $true
            }
            if ($AttemptedPlans -and $RunId -and [string]$row.run_id -eq $RunId -and $row.umbraco_version -and $row.infra_tier -and $row.jmeter_test_name) {
                $AttemptedPlans.Value["$($row.umbraco_version)__$($row.infra_tier)__$($row.jmeter_test_name)"] = $true
            }
            if (-not $row.scenario_name) { continue }
            if ($OnlyRunIds.Count -gt 0 -and [string]$row.run_id -notin $OnlyRunIds) { continue }
            if ($ExcludeRunIds.Count -gt 0 -and [string]$row.run_id -in $ExcludeRunIds) { continue }
            if ($Since) {
                $started = Get-RunDate $row
                # PowerShell unwraps Nullable[datetime], so $Since is the DateTime itself.
                # Get-RunDate is UTC, and so is the cut (ConvertTo-SinceUtc).
                if ($null -eq $started -or $started -lt (ConvertTo-SinceUtc ([datetime]$Since))) { continue }
            }
            # Match the Workbook's filters so every Get-HistoryCells consumer
            # (regression gate, compare-runs, show-trends) works over the same
            # population the dashboard shows: warm, ok rows. Without this the
            # regression baseline mixes cold-start (JIT-inflated) and failed runs
            # into the median and disagrees with the dashboard.
            if ($row.parse_status -and $row.parse_status -ne 'ok') { continue }
            if ($row.cold_start -eq $true) { continue }
            # Pre-TC-discrimination historical rows (old majors, before backoffice
            # publish was fixed to keep only Transaction Controller labels) carry a
            # raw per-request sampler name instead of a 'NN. Step' TC label.
            #
            # Structural, not path-shaped: a post-fix backoffice row ALWAYS reads
            # "<jmeter_test_name> / <label>", so anything else is pre-fix. The
            # previous rule matched only management-API paths and missed 1,237
            # rows across 706 samplers - 'GET /', 'GET /umbraco',
            # 'POST /umbraco/api/memberlogin/login' (p95 to 17s), relative tree
            # paths, and un-prefixed TC labels. Verified against 15,196 live rows:
            # this separates 14,372 pre-fix from 824 post-fix with no overlap and
            # no false positives, and it self-maintains if prefixing ever
            # regresses. Frontend rows have no jmeter_test_name, so they're exempt.
            if ($row.jmeter_test_name -and -not $row.scenario_name.StartsWith("$($row.jmeter_test_name) / ")) { continue }
            # The structural rule above can't see rows from before jmeter_test_name
            # was published at all. The rule it replaced caught those by path, so
            # it stays for them: a raw management-API request is never a Locust
            # task name or a Transaction Controller label.
            if (-not $row.jmeter_test_name -and $row.scenario_name -match '^(GET|POST|PUT|DELETE|PATCH) /umbraco/management/api/') { continue }
            # Backoffice rows are published as "$JmeterTestName / $label" (e.g.
            # 'SaveContent / 01. Save content'), so a bare-label -Sampler value
            # (the style used across every -Sampler example in this repo) must
            # also match the label half, not just the full scenario_name.
            if ($Sampler -and $row.scenario_name -ne $Sampler -and -not $row.scenario_name.EndsWith(" / $Sampler")) { continue }

            $cellKey = "$($row.umbraco_version)__$($row.infra_tier)__$($row.scenario_name)"
            if (-not $cells.ContainsKey($cellKey)) {
                # List[object] for O(1) appends; += on PowerShell arrays is
                # O(N²) on long histories and dominates wall-clock of every
                # downstream analysis script.
                $cells[$cellKey] = [System.Collections.Generic.List[object]]::new()
            }
            $cells[$cellKey].Add($row)
        }
    }

    return $cells
}
