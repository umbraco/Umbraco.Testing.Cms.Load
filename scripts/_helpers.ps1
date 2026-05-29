# Shared helpers; dot-source via `. "$PSScriptRoot/_helpers.ps1"`.

# Nearest-rank percentile (ceil-based, so p99 of N=100 is the 99th value, not max).
function Get-Pct ($Sorted, [double]$Pct) {
    if ($Sorted.Count -eq 0) { return 0 }
    $i = [int][math]::Ceiling($Sorted.Count * $Pct / 100.0) - 1
    if ($i -lt 0) { $i = 0 }
    if ($i -gt $Sorted.Count - 1) { $i = $Sorted.Count - 1 }
    return $Sorted[$i]
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

function Get-UmbracoMajor([string] $Version) {
    $raw = ($Version -split '\.')[0]
    $major = 0
    if (-not [int]::TryParse($raw, [ref]$major)) {
        Write-PipelineError "Cannot parse Umbraco major from '$Version' (expected X.Y.Z[-suffix])."
    }
    return $major
}

# Stream-parse one engine_results.csv (JMeter format). Memory-bounded: keeps
# per-task sample lists, not the whole CSV. Returns:
#   @{ ByLabel = @{ '<label>' = @{ Samples = List[int]; Errors = int } };
#      AllElapsed = List[int]    # only when -BuildAggregate
#      TotalErrors = int         # only when -BuildAggregate
#   }
function Parse-JmeterCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [switch]$BuildAggregate,
        # Inverts the TC/sampler filter (see comment below). Default off keeps
        # the historical Locust/HTTP-sampler-only behaviour; backoffice (JMeter)
        # callers pass this to keep TC rows and drop the per-request rows.
        [switch]$OnlyTransactionControllers
    )

    $byLabel = @{}
    $allElapsed = if ($BuildAggregate) { New-Object 'System.Collections.Generic.List[int]' } else { $null }
    $totalErrors = 0

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
        $reader.ReadLine() | Out-Null  # discard header
        while ($null -ne ($line = $reader.ReadLine())) {
            $cols = $line.Split(',')
            if ($cols.Length -lt 8) { continue }
            $elapsed = 0
            if (-not [int]::TryParse($cols[1], [ref]$elapsed)) { continue }
            $label   = $cols[2]
            if ($OnlyTransactionControllers) {
                if ($label -notmatch $tcLabelPattern) { continue }
            } else {
                if ($label -match $tcLabelPattern) { continue }
            }
            $success = $cols[7] -ieq 'true'

            $bucket = $byLabel[$label]
            if (-not $bucket) {
                $bucket = @{
                    Samples = (New-Object 'System.Collections.Generic.List[int]')
                    Errors  = 0
                }
                $byLabel[$label] = $bucket
            }
            $bucket.Samples.Add($elapsed)
            if (-not $success) { $bucket.Errors++ }

            if ($BuildAggregate) {
                $allElapsed.Add($elapsed)
                if (-not $success) { $totalErrors++ }
            }
        }
    } finally { $reader.Dispose() }

    return @{
        ByLabel     = $byLabel
        AllElapsed  = $allElapsed
        TotalErrors = $totalErrors
    }
}
