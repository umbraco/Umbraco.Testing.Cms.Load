# Shared helpers for scripts that read summary.ndjson rows out of history storage.
# Dot-source from a script:
#   . "$PSScriptRoot/_history-helpers.ps1"
# Then call Get-HistoryCells / Get-Median / Get-HistoryPrefix.
#
# Generic helpers (storage key, percentile, error exit) live in _helpers.ps1 —
# pulled in here so callers only have to dot-source one file.

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
function Get-RunDate {
    param([Parameter(Mandatory)] $Row)
    try {
        return [datetime]::Parse([string]$Row.run_started_at, [System.Globalization.CultureInfo]::InvariantCulture)
    } catch {
        return $null
    }
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
        [string]$Sampler
    )

    $prefix = Get-HistoryPrefix -Scenario $Scenario -Major $Major

    $storageKey = Get-StorageAccountKey -StorageAccountName $StorageAccountName -ResourceGroupName $HistoryResourceGroup

    Write-Host "Listing blobs under $prefix..."
    $listJson = az storage blob list `
        --account-name $StorageAccountName --account-key $storageKey `
        --container-name $ContainerName `
        --prefix $prefix `
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
            if (-not $row.scenario_name) { continue }
            if ($Sampler -and $row.scenario_name -ne $Sampler) { continue }

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
