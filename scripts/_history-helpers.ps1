# Shared helpers for scripts that read summary.ndjson rows out of history storage.
# Dot-source from a script:
#   . "$PSScriptRoot/_history-helpers.ps1"
# Then call Get-HistoryCells / Get-Median / Get-HistoryPrefix.
#
# The leading underscore signals "internal helper, not a top-level CLI" so it
# stands apart in directory listings.

function Get-HistoryPrefix {
    param (
        [Parameter(Mandatory = $true)] [string]$Scenario,
        [string]$Major
    )
    if ($Major) { "$Scenario/$Major/" } else { "$Scenario/" }
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

    # Uses account-key auth: the caller needs Storage Account Contributor (or any
    # role with Microsoft.Storage/storageAccounts/listKeys/action) on the SA so
    # `az storage account keys list` works. The pipeline SP already has this;
    # local dev users with Reader+ on the subscription typically do too.

    $prefix = Get-HistoryPrefix -Scenario $Scenario -Major $Major

    $storageKey = az storage account keys list -n $StorageAccountName -g $HistoryResourceGroup --query "[0].value" -o tsv
    if (-not $storageKey) {
        Write-Error "Could not read storage key for '$StorageAccountName' in '$HistoryResourceGroup'."
        exit 1
    }

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
            if (-not $cells.ContainsKey($cellKey)) { $cells[$cellKey] = @() }
            $cells[$cellKey] += $row
        }
    }

    return $cells
}
