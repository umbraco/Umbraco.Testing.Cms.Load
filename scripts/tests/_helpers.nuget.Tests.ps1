# Verifies Test-NuGetPackageVersionExists's feed walk without network: a 404
# moves to the next feed, an unreachable feed is skipped with a warning, and
# only all-unreachable throws.
BeforeAll {
    . "$PSScriptRoot/../_helpers.ps1"

    function New-NotFound {
        $resp = [System.Net.Http.HttpResponseMessage]::new(404)
        return [Microsoft.PowerShell.Commands.HttpResponseException]::new('not found', $resp)
    }
}

Describe 'Test-NuGetPackageVersionExists' {
    It 'returns true when a later feed has the version after an earlier 404' {
        Mock Invoke-RestMethod { throw (New-NotFound) } -ParameterFilter { $Uri -like 'https://feed1/*' }
        Mock Invoke-RestMethod { @{ versions = @('1.0.0', '2.0.0-nightly.1') } } -ParameterFilter { $Uri -like 'https://feed2/*' }
        Test-NuGetPackageVersionExists -PackageId 'Pkg' -Version '2.0.0-nightly.1' -FlatContainerUrls @('https://feed1', 'https://feed2/') | Should -BeTrue
        Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter { $Uri -eq 'https://feed2/pkg/index.json' }
    }
    It 'returns false when every feed answers 404' {
        Mock Invoke-RestMethod { throw (New-NotFound) }
        Test-NuGetPackageVersionExists -PackageId 'Pkg' -Version '1.0.0' -FlatContainerUrls @('https://feed1', 'https://feed2') | Should -BeFalse
        Should -Invoke Invoke-RestMethod -Times 2
    }
    It 'returns false when the version is on no feed' {
        Mock Invoke-RestMethod { @{ versions = @('1.0.0') } }
        Test-NuGetPackageVersionExists -PackageId 'Pkg' -Version '9.9.9' -FlatContainerUrls @('https://feed1') | Should -BeFalse
    }
    It 'matches the version case-insensitively' {
        Mock Invoke-RestMethod { @{ versions = @('18.2.0-rc') } }
        Test-NuGetPackageVersionExists -PackageId 'Pkg' -Version '18.2.0-RC' -FlatContainerUrls @('https://feed1') | Should -BeTrue
    }
    It 'skips an unreachable feed with a warning and keeps checking' {
        Mock Invoke-RestMethod { throw [System.Net.Http.HttpRequestException]::new('no such host') } -ParameterFilter { $Uri -like 'https://feed1/*' }
        Mock Invoke-RestMethod { @{ versions = @('1.0.0') } } -ParameterFilter { $Uri -like 'https://feed2/*' }
        $result = Test-NuGetPackageVersionExists -PackageId 'Pkg' -Version '1.0.0' -FlatContainerUrls @('https://feed1', 'https://feed2') -WarningVariable w 3>$null
        $result | Should -BeTrue
        $w | Should -Not -BeNullOrEmpty
    }
    It 'throws only when every feed is unreachable' {
        Mock Invoke-RestMethod { throw [System.Net.Http.HttpRequestException]::new('no such host') }
        { Test-NuGetPackageVersionExists -PackageId 'Pkg' -Version '1.0.0' -FlatContainerUrls @('https://feed1', 'https://feed2') 3>$null } | Should -Throw '*could not be checked*'
    }
}
