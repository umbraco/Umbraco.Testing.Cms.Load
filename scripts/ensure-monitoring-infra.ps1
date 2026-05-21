#requires -Version 7.3

# Idempotently ensure the long-lived "monitoring" infra exists: a Log Analytics
# workspace, a custom table for load-test summary rows, a Data Collection
# Endpoint + Rule for the Logs Ingestion API, and a role assignment so the
# pipeline service principal can POST rows.
#
# First run creates; subsequent runs no-op (or reconcile drift on the table /
# DCR JSON). Mirrors the ensure-history-infra.ps1 pattern.
#
# Outputs at the end (also written to the named env-vars when -EmitPipelineVars
# is set, so an Azure DevOps task can hand them to publish-load-test-results.ps1):
#   - DceUri
#   - DcrImmutableId
#   - StreamName  (Custom-LoadTestSummary_CL)
#
# Prereqs:
#   - az CLI logged in
#   - History RG already exists (created by ensure-history-infra.ps1)
#   - The pipeline service principal's object ID (-IngestPrincipalId)

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$HistoryResourceGroup,
    [Parameter(Mandatory = $true)] [string]$HistoryLocation,
    [Parameter(Mandatory = $true)] [string]$WorkspaceName,
    [Parameter(Mandatory = $true)] [string]$DceName,
    [Parameter(Mandatory = $true)] [string]$DcrName,
    [Parameter(Mandatory = $true)] [string]$IngestPrincipalId,
    [string]$TableName = "LoadTestSummary_CL",
    # Companion table for per-minute resource-pressure time series. One row per
    # (run × metric × minute) — populated by publish-load-test-results.ps1 from
    # the raw Azure Monitor datapoints that Get-MetricSummary today averages
    # away. The dashboard's per-run drill-down reads from this.
    [string]$SeriesTableName = "LoadTestSeries_CL",
    # Days the custom tables retain data. LA includes 31 days free; beyond
    # that is ~$0.12/GB/month. At our row size + cadence this is fractions
    # of a cent per year for 365-day retention. Bumping >2y requires Sentinel
    # or an Auxiliary Logs tier — out of scope here.
    [int]$RetentionDays = 365,
    [switch]$EmitPipelineVars
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

$tags = @("project=umbraco-loadtest", "managed_by=ensure-script")

# Schema shared between the custom table and the DCR's stream declaration. Keep
# in sync with the field set produced by publish-load-test-results.ps1's
# $metadata + per-sampler row construction. Columns added here without a
# matching field in the publisher are tolerated (ingest as null); fields added
# in the publisher without a matching column here are dropped at ingestion.
$columns = @(
    @{ name = "TimeGenerated";                          type = "datetime" }
    # Same wall-clock value as TimeGenerated today (both sourced from
    # $(System.PipelineStartTime)) but kept distinct so the original run
    # time survives any future re-ingest or backfill that would otherwise
    # overwrite TimeGenerated with the ingest moment.
    @{ name = "run_started_at";                         type = "datetime" }
    @{ name = "run_id";                                 type = "string"   }
    @{ name = "test_case_id";                           type = "string"   }
    @{ name = "commit";                                 type = "string"   }
    @{ name = "branch";                                 type = "string"   }
    @{ name = "umbraco_version";                        type = "string"   }
    @{ name = "dotnet_version";                         type = "string"   }
    @{ name = "app_service_sku";                        type = "string"   }
    @{ name = "sql_sku";                                type = "string"   }
    # pool_dtu_max replaces sql_sku in the Elastic Pool model (per-DB DTU cap).
    # sql_sku is kept as a column so any historical rows from before the rename
    # remain queryable; new rows write pool_dtu_max and leave sql_sku empty.
    @{ name = "pool_dtu_max";                           type = "int"      }
    @{ name = "seeder_preset";                          type = "string"   }
    @{ name = "seeder_duration_seconds";                type = "real"     }
    @{ name = "infra_tier";                             type = "string"   }
    @{ name = "scenario";                               type = "string"   }
    @{ name = "scenario_name";                          type = "string"   }
    # Backoffice JMeter mode emits one publish per .jmx file (ViewHomePage,
    # MemberLogin, SaveContent, ...). jmeter_test_name carries the .jmx stem
    # so the dashboard can split per-test results within a single (version ×
    # tier) run. Empty for Locust runs and for backoffice runs that pre-date
    # the multi-.jmx loop.
    @{ name = "jmeter_test_name";                       type = "string"   }
    @{ name = "request_type";                           type = "string"   }
    @{ name = "parse_status";                           type = "string"   }
    @{ name = "user_count";                             type = "int"      }
    @{ name = "spawn_rate";                             type = "int"      }
    @{ name = "duration_seconds";                       type = "int"      }
    @{ name = "cold_start";                             type = "boolean"  }
    @{ name = "request_count";                          type = "int"      }
    @{ name = "failure_count";                          type = "int"      }
    @{ name = "engine_count";                           type = "int"      }
    @{ name = "error_rate";                             type = "real"     }
    @{ name = "avg_ms";                                 type = "real"     }
    @{ name = "p50_ms";                                 type = "real"     }
    @{ name = "p90_ms";                                 type = "real"     }
    @{ name = "p95_ms";                                 type = "real"     }
    @{ name = "p99_ms";                                 type = "real"     }
    @{ name = "min_ms";                                 type = "real"     }
    @{ name = "max_ms";                                 type = "real"     }
    @{ name = "requests_per_sec";                       type = "real"     }
    @{ name = "plan_CpuPercentage_avg";                 type = "real"     }
    @{ name = "plan_CpuPercentage_max";                 type = "real"     }
    @{ name = "plan_MemoryPercentage_avg";              type = "real"     }
    @{ name = "plan_MemoryPercentage_max";              type = "real"     }
    @{ name = "sql_dtu_consumption_percent_avg";        type = "real"     }
    @{ name = "sql_dtu_consumption_percent_max";        type = "real"     }
    @{ name = "sql_cpu_percent_avg";                    type = "real"     }
    @{ name = "sql_cpu_percent_max";                    type = "real"     }
    @{ name = "sql_log_write_percent_avg";              type = "real"     }
    @{ name = "sql_log_write_percent_max";              type = "real"     }
    @{ name = "sql_physical_data_read_percent_avg";     type = "real"     }
    @{ name = "sql_physical_data_read_percent_max";     type = "real"     }
    @{ name = "app_Http5xx_avg";                        type = "real"     }
    @{ name = "app_Http5xx_max";                        type = "real"     }
    @{ name = "app_Http4xx_avg";                        type = "real"     }
    @{ name = "app_Http4xx_max";                        type = "real"     }
    # Regression-check status fields. Populated by check-regression.ps1 in the
    # regressionCheck stage AFTER the load test completes. Rows with these
    # fields have parse_status='regression_check' as the row-type marker so
    # the Workbook can filter them in/out of summary queries cleanly.
    @{ name = "regression_status";                      type = "string"   }
    @{ name = "regressed_samplers";                     type = "string"   }
    @{ name = "regressed_count";                        type = "int"      }
)

# Per-minute time-series schema. Long, narrow, additive — one row per
# (run × metric × minute). Joined back to LoadTestSummary_CL by run_id when the
# workbook needs run-level context (scenario / version / tier already replicated
# here so the panel can render without a join for the common single-run drill).
$seriesColumns = @(
    @{ name = "TimeGenerated";    type = "datetime" }
    @{ name = "run_id";           type = "string"   }
    @{ name = "scenario";         type = "string"   }
    @{ name = "umbraco_version";  type = "string"   }
    @{ name = "infra_tier";       type = "string"   }
    # Per-.jmx tag (matches LoadTestSummary_CL's jmeter_test_name column).
    # Empty for Locust runs; populated for backoffice (JMeter) runs so the
    # dashboard can filter per-minute metrics to one .jmx file's execution
    # phase. Without this, the per-run drill-down chart shows all 6 .jmx
    # iterations concatenated on the time axis with no way to slice.
    @{ name = "jmeter_test_name"; type = "string"   }
    @{ name = "metric_name";      type = "string"   }
    @{ name = "value";            type = "real"     }
)

$streamName       = "Custom-$TableName"
$seriesStreamName = "Custom-$SeriesTableName"

Write-Host "=== Ensuring monitoring infrastructure ==="
Write-Host "  RG:               $HistoryResourceGroup"
Write-Host "  Location:         $HistoryLocation"
Write-Host "  Workspace:        $WorkspaceName"
Write-Host "  Custom tables:    $TableName, $SeriesTableName (retention $RetentionDays days)"
Write-Host "  DCE / DCR:        $DceName / $DcrName"
Write-Host "  Ingest principal: $IngestPrincipalId"
Write-Host ""

function Test-AzResource([scriptblock] $Probe) {
    try { return [bool](& $Probe 2>$null) } catch { return $false }
}

# Resource group (history RG should already exist; create defensively).
Write-Host "-> Resource group"
if ((az group exists -n $HistoryResourceGroup) -eq 'true') {
    Write-Host "   already exists"
}
else {
    az group create -n $HistoryResourceGroup -l $HistoryLocation --tags $tags | Out-Null
    Write-Host "   created"
}

$subId = az account show --query id -o tsv

# Log Analytics workspace
Write-Host "-> Log Analytics workspace"
if (Test-AzResource { az monitor log-analytics workspace show -n $WorkspaceName -g $HistoryResourceGroup }) {
    Write-Host "   already exists"
}
else {
    az monitor log-analytics workspace create `
        -n $WorkspaceName `
        -g $HistoryResourceGroup `
        -l $HistoryLocation `
        --tags $tags | Out-Null
    Write-Host "   created"
}
$workspaceId = az monitor log-analytics workspace show -n $WorkspaceName -g $HistoryResourceGroup --query id -o tsv

# Custom tables. The az CLI's `monitor log-analytics workspace table create` doesn't
# expose the DCR-based custom-log path, so call the REST API directly. PUT is
# idempotent — re-running with the same schema is a no-op; adding columns is
# accepted as an in-place schema update.
function Set-CustomTable {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [object[]]$Columns
    )
    Write-Host "-> Custom table $Name"
    $body = @{
        properties = @{
            retentionInDays = $RetentionDays
            schema = @{
                name    = $Name
                columns = $Columns
            }
        }
    } | ConvertTo-Json -Depth 6 -Compress
    $path = "/subscriptions/$subId/resourceGroups/$HistoryResourceGroup/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName/tables/${Name}?api-version=2022-10-01"
    $bodyFile = Join-Path ([IO.Path]::GetTempPath()) "loadtest-table-$([Guid]::NewGuid()).json"
    try {
        $body | Out-File -FilePath $bodyFile -Encoding utf8 -NoNewline
        az rest --method put --url "https://management.azure.com$path" --body "@$bodyFile" --headers "Content-Type=application/json" | Out-Null
        Write-Host "   created/updated"
    }
    finally {
        Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue
    }
}

Set-CustomTable -Name $TableName       -Columns $columns
Set-CustomTable -Name $SeriesTableName -Columns $seriesColumns

# Data Collection Endpoint
Write-Host "-> Data Collection Endpoint"
if (Test-AzResource { az monitor data-collection endpoint show -n $DceName -g $HistoryResourceGroup }) {
    Write-Host "   already exists"
}
else {
    az monitor data-collection endpoint create `
        -n $DceName `
        -g $HistoryResourceGroup `
        -l $HistoryLocation `
        --public-network-access Enabled `
        --tags $tags | Out-Null
    Write-Host "   created"
}
$dceShow = az monitor data-collection endpoint show -n $DceName -g $HistoryResourceGroup -o json | ConvertFrom-Json
$dceId   = $dceShow.id
$dceUri  = $dceShow.logsIngestion.endpoint

# Data Collection Rule. Same idempotency story as the table — PUT through REST
# because the az CLI's DCR commands don't cover the Logs-Ingestion-API direct
# stream shape.
Write-Host "-> Data Collection Rule"
$dcrBody = @{
    location   = $HistoryLocation
    tags       = @{ project = "umbraco-loadtest"; managed_by = "ensure-script" }
    properties = @{
        dataCollectionEndpointId = $dceId
        streamDeclarations       = @{
            $streamName       = @{ columns = $columns }
            $seriesStreamName = @{ columns = $seriesColumns }
        }
        destinations             = @{
            logAnalytics = @(
                @{ name = "loadtest-workspace"; workspaceResourceId = $workspaceId }
            )
        }
        dataFlows                = @(
            @{
                streams      = @($streamName)
                destinations = @("loadtest-workspace")
                outputStream = $streamName
                transformKql = "source"
            },
            @{
                streams      = @($seriesStreamName)
                destinations = @("loadtest-workspace")
                outputStream = $seriesStreamName
                transformKql = "source"
            }
        )
    }
} | ConvertTo-Json -Depth 8 -Compress

$dcrPath = "/subscriptions/$subId/resourceGroups/$HistoryResourceGroup/providers/Microsoft.Insights/dataCollectionRules/${DcrName}?api-version=2022-06-01"
$dcrBodyFile = Join-Path ([IO.Path]::GetTempPath()) "loadtest-dcr-$([Guid]::NewGuid()).json"
try {
    $dcrBody | Out-File -FilePath $dcrBodyFile -Encoding utf8 -NoNewline
    az rest --method put --url "https://management.azure.com$dcrPath" --body "@$dcrBodyFile" --headers "Content-Type=application/json" | Out-Null
    Write-Host "   created/updated"
}
finally {
    Remove-Item $dcrBodyFile -Force -ErrorAction SilentlyContinue
}
$dcrShow         = az rest --method get --url "https://management.azure.com$dcrPath" -o json | ConvertFrom-Json
$dcrId           = $dcrShow.id
$dcrImmutableId  = $dcrShow.properties.immutableId

# Role assignment: Monitoring Metrics Publisher on the DCR. Built-in role GUID
# is stable across tenants. Skip if an assignment for this principal already
# exists at this scope (re-running shouldn't accumulate duplicates).
Write-Host "-> Role assignment (Monitoring Metrics Publisher)"
$roleId = "3913510d-42f4-4e42-8a64-420c390055eb"
# @() forces array semantics: ConvertFrom-Json on '[]' returns $null in PS, so a
# bare $existing.Count would be missing instead of 0.
$existing = @(az role assignment list --assignee $IngestPrincipalId --scope $dcrId --role $roleId -o json | ConvertFrom-Json)
if ($existing.Count -gt 0) {
    Write-Host "   already assigned"
}
else {
    # Locally disable the throw-on-nonzero-exit preference so we can inspect
    # $LASTEXITCODE and print a useful remediation if the caller lacks
    # Microsoft.Authorization/roleAssignments/write at the DCR scope. The raw
    # NativeCommandExitException with the AuthorizationFailed payload buried
    # in the stack trace is unhelpful — the next person to fork this and hit
    # it would have to reverse-engineer what's needed.
    $prevPref = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $createOutput = & az role assignment create `
            --assignee-object-id $IngestPrincipalId `
            --assignee-principal-type ServicePrincipal `
            --role $roleId `
            --scope $dcrId 2>&1
        $createExit = $LASTEXITCODE
    }
    finally {
        $PSNativeCommandUseErrorActionPreference = $prevPref
    }

    if ($createExit -eq 0) {
        Write-Host "   assigned"
    }
    elseif (($createOutput | Out-String) -match "AuthorizationFailed") {
        Write-Host ""
        Write-Host "=========================================================================="
        Write-Host "  Cannot auto-grant Monitoring Metrics Publisher on the DCR."
        Write-Host "  The principal running this script lacks"
        Write-Host "  Microsoft.Authorization/roleAssignments/write at the DCR scope."
        Write-Host ""
        Write-Host "  One-time fix — pick CLI or portal, then re-queue the pipeline."
        Write-Host ""
        Write-Host "  CLI (as a User Access Administrator on the RG):"
        Write-Host ""
        # PowerShell line-continuation char as a [char] literal — avoids all the
        # escape-in-string ambiguity around printing trailing backticks.
        $bt = [char]96
        Write-Host "    az role assignment create $bt"
        Write-Host "      --assignee-object-id $IngestPrincipalId $bt"
        Write-Host "      --assignee-principal-type ServicePrincipal $bt"
        Write-Host "      --role 'Monitoring Metrics Publisher' $bt"
        Write-Host "      --scope $dcrId"
        Write-Host ""
        Write-Host "  Portal: open the DCR (RG '$HistoryResourceGroup', resource '$DcrName')"
        Write-Host "          -> Access control (IAM) -> Add role assignment"
        Write-Host "    Role:   Monitoring Metrics Publisher"
        Write-Host "    Member: paste object ID  $IngestPrincipalId"
        Write-Host ""
        Write-Host "  The existence check above will see the grant on the next run and skip"
        Write-Host "  this step entirely."
        Write-Host "=========================================================================="
        Write-Host ""
        throw "Monitoring Metrics Publisher role grant requires a one-time manual setup. See remediation above."
    }
    else {
        # Anything else — quota, transient, network — surface the raw output.
        throw "az role assignment create failed (exit $createExit): $($createOutput | Out-String)"
    }
}

Write-Host ""
Write-Host "Monitoring infrastructure ready."
Write-Host ""
Write-Host "Wire these into publish-load-test-results.ps1 (or pass via pipeline variables):"
Write-Host "  DceUri:           $dceUri"
Write-Host "  DcrImmutableId:   $dcrImmutableId"
Write-Host "  StreamName:       $streamName"
Write-Host "  SeriesStreamName: $seriesStreamName"

if ($EmitPipelineVars) {
    # Azure DevOps logging-command output. isOutput=true is required for these
    # to cross stages (the publishing step lives in a later stage that depends
    # on the one running this script).
    Write-Host "##vso[task.setvariable variable=MonitoringDceUri;isOutput=true]$dceUri"
    Write-Host "##vso[task.setvariable variable=MonitoringDcrImmutableId;isOutput=true]$dcrImmutableId"
    Write-Host "##vso[task.setvariable variable=MonitoringStreamName;isOutput=true]$streamName"
    Write-Host "##vso[task.setvariable variable=MonitoringSeriesStreamName;isOutput=true]$seriesStreamName"
}
