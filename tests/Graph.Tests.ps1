BeforeAll {
    # The tests must run without the Microsoft Graph SDK installed (CI has no tenant and no SDK).
    # Pester can only mock commands that exist, so define empty stand-ins when the SDK is absent.
    $script:createdStubs = @()
    if (-not (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
        function global:Invoke-MgGraphRequest { [CmdletBinding()] param($Method, $Uri, $OutputType) }
        $script:createdStubs += 'Invoke-MgGraphRequest'
    }
    if (-not (Get-Command Get-MgContext -ErrorAction SilentlyContinue)) {
        function global:Get-MgContext { [CmdletBinding()] param() }
        $script:createdStubs += 'Get-MgContext'
    }

    Import-Module (Join-Path $PSScriptRoot '../src/M365Health/M365Health.psd1') -Force
}

AfterAll {
    foreach ($name in $script:createdStubs) {
        Remove-Item -Path "function:global:$name" -ErrorAction SilentlyContinue
    }
}

Describe 'Invoke-GraphCollection' {
    It 'follows @odata.nextLink until the last page' {
        Mock Invoke-MgGraphRequest -ModuleName M365Health -ParameterFilter { $Uri -eq 'v1.0/things' } {
            [pscustomobject]@{ value = @('a', 'b'); '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/things?$skiptoken=page2' }
        }
        Mock Invoke-MgGraphRequest -ModuleName M365Health -ParameterFilter { $Uri -like '*skiptoken=page2' } {
            [pscustomobject]@{ value = @('c') }
        }

        $items = InModuleScope M365Health { Invoke-GraphCollection -Uri 'v1.0/things' }

        $items | Should -Be @('a', 'b', 'c')
        Should -Invoke Invoke-MgGraphRequest -ModuleName M365Health -Times 2 -Exactly
    }

    It 'returns nothing for an empty collection' {
        Mock Invoke-MgGraphRequest -ModuleName M365Health { [pscustomobject]@{ value = @() } }
        InModuleScope M365Health { Invoke-GraphCollection -Uri 'v1.0/empty' } | Should -BeNullOrEmpty
    }
}

Describe 'Get-M365TenantSnapshot' {
    It 'refuses to run without a Graph connection' {
        Mock Get-MgContext -ModuleName M365Health { $null }
        { Get-M365TenantSnapshot } | Should -Throw '*Connect-MgGraph*'
    }

    It 'reads users with sign-in activity, the MFA registration report and the subscribed SKUs' {
        Mock Get-MgContext -ModuleName M365Health { [pscustomobject]@{ TenantId = 'test' } }
        Mock Invoke-GraphCollection -ModuleName M365Health { [pscustomobject]@{ uri = $Uri } }

        $result = Get-M365TenantSnapshot

        $result.Users[0].uri | Should -BeLike 'v1.0/users?$select=*signInActivity*'
        $result.RegistrationDetails[0].uri | Should -Be 'v1.0/reports/authenticationMethods/userRegistrationDetails'
        $result.SubscribedSkus[0].uri | Should -Be 'v1.0/subscribedSkus'
        $result.CollectedAt | Should -BeOfType [datetime]
    }

    It 'only ever issues GET requests' {
        Mock Get-MgContext -ModuleName M365Health { [pscustomobject]@{ TenantId = 'test' } }
        Mock Invoke-MgGraphRequest -ModuleName M365Health { [pscustomobject]@{ value = @() } }

        $null = Get-M365TenantSnapshot

        Should -Invoke Invoke-MgGraphRequest -ModuleName M365Health -Times 3 -Exactly -ParameterFilter { $Method -eq 'GET' }
        Should -Invoke Invoke-MgGraphRequest -ModuleName M365Health -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
    }
}

Describe 'Module surface' {
    It 'exports only the public functions' {
        (Get-Command -Module M365Health).Name | Sort-Object | Should -Be @(
            'Find-IdleLicense'
            'Find-UnregisteredMfaUser'
            'Get-M365TenantSnapshot'
            'Invoke-M365HealthCheck'
        )
    }
}
