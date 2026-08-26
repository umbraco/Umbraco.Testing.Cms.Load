# Covers Test-HistoryRowIncluded, the filter deciding which runs form a
# regression baseline. It has no crash mode - a wrong rule is silently wrong.

BeforeAll {
    . "$PSScriptRoot/../_history-helpers.ps1"

    # In BeforeAll, not at script scope: Pester 5 runs the top-level body during
    # Discovery. Minimal valid row; each test overrides the field under test.
    function New-Row {
        param([hashtable]$Override = @{})
        $base = @{
            scenario_name   = 'Detail'
            parse_status    = 'ok'
            cold_start      = $false
            umbraco_version = '17.0.0'
            infra_tier      = 'Starter'
            p95_ms          = 100
        }
        foreach ($k in $Override.Keys) { $base[$k] = $Override[$k] }
        return [pscustomobject]$base
    }
}

Describe 'Test-HistoryRowIncluded' {
    It 'keeps a warm, ok, named row' {
        Test-HistoryRowIncluded -Row (New-Row) | Should -BeTrue
    }

    It 'drops a metadata-only row (no scenario_name)' {
        Test-HistoryRowIncluded -Row (New-Row @{ scenario_name = $null }) | Should -BeFalse
    }

    It 'drops a $null row rather than throwing' {
        Test-HistoryRowIncluded -Row $null | Should -BeFalse
    }

    It 'drops rows whose parse_status is not ok' {
        foreach ($status in @('no_metrics', 'ok_no_samples', 'no_results_dir', 'regression_check')) {
            Test-HistoryRowIncluded -Row (New-Row @{ parse_status = $status }) |
                Should -BeFalse -Because "parse_status '$status' is not a real measurement row"
        }
    }

    It 'keeps a row with no parse_status at all (pre-feature history)' {
        Test-HistoryRowIncluded -Row (New-Row @{ parse_status = $null }) | Should -BeTrue
    }

    It 'drops cold-start rows so JIT-inflated runs stay out of the baseline' {
        Test-HistoryRowIncluded -Row (New-Row @{ cold_start = $true }) | Should -BeFalse
    }

    It 'keeps warm rows when cold_start is false or absent' {
        Test-HistoryRowIncluded -Row (New-Row @{ cold_start = $false }) | Should -BeTrue
        Test-HistoryRowIncluded -Row (New-Row @{ cold_start = $null })  | Should -BeTrue
    }

    # The 2026-08-22 false-positive class: pre-TC-discrimination rows carrying a
    # raw management-API path as the sampler identity.
    It 'drops raw management-API paths used as sampler names' {
        $rawSamplers = @(
            'GET /umbraco/management/api/v1/language'
            'POST /umbraco/management/api/v1/document'
            'PUT /umbraco/management/api/v1/document-type/0099b49e-1111-2222-3333-444455556666'
            'DELETE /umbraco/management/api/v1/document/abc'
            'PATCH /umbraco/management/api/v1/user'
        )
        foreach ($s in $rawSamplers) {
            Test-HistoryRowIncluded -Row (New-Row @{ scenario_name = $s }) |
                Should -BeFalse -Because "'$s' is a raw per-request path, not a Transaction Controller label"
        }
    }

    It 'keeps Transaction Controller labels that merely mention the API' {
        # The exclusion must be anchored on the "VERB /umbraco/management/api/"
        # shape, not on the substring — a TC label is legitimate data.
        Test-HistoryRowIncluded -Row (New-Row @{ scenario_name = 'SaveContent / 01. POST /umbraco/management/api/v1/document' }) |
            Should -BeTrue
    }

    It 'keeps normal backoffice TC labels' {
        Test-HistoryRowIncluded -Row (New-Row @{ scenario_name = 'SaveContent / 01. Save content' }) | Should -BeTrue
    }

    Context 'Sampler filter' {
        It 'matches an exact scenario_name' {
            Test-HistoryRowIncluded -Row (New-Row @{ scenario_name = 'Detail' }) -Sampler 'Detail' | Should -BeTrue
        }

        It 'matches a bare label against a "<jmx> / <label>" row' {
            # Every -Sampler example in the repo passes a bare label, so the
            # prefixed backoffice form has to match too.
            Test-HistoryRowIncluded -Row (New-Row @{ scenario_name = 'SaveContent / 01. Save content' }) `
                -Sampler '01. Save content' | Should -BeTrue
        }

        It 'matches the fully-qualified backoffice name' {
            Test-HistoryRowIncluded -Row (New-Row @{ scenario_name = 'SaveContent / 01. Save content' }) `
                -Sampler 'SaveContent / 01. Save content' | Should -BeTrue
        }

        It 'rejects a non-matching sampler' {
            Test-HistoryRowIncluded -Row (New-Row @{ scenario_name = 'Detail' }) -Sampler 'Homepage' | Should -BeFalse
        }

        It 'does not match on a partial suffix without the " / " separator' {
            # 'Content' must not match 'SaveContent' — that would silently merge
            # unrelated samplers into one cell.
            Test-HistoryRowIncluded -Row (New-Row @{ scenario_name = 'SaveContent' }) -Sampler 'Content' | Should -BeFalse
        }

        It 'keeps every row when no sampler is given' {
            Test-HistoryRowIncluded -Row (New-Row @{ scenario_name = 'Anything' }) | Should -BeTrue
        }
    }
}
