BeforeAll {
    . (Join-Path $PSScriptRoot 'GraphStubs.ps1')
    $script:createdStubs = Add-GraphStubs

    Import-Module (Join-Path $PSScriptRoot '../src/M365Health/M365Health.psd1') -Force
}

AfterAll {
    Remove-GraphStubs $script:createdStubs
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

    It 'refuses the consumer directory of personal Microsoft accounts, before calling Graph' {
        Mock Get-MgContext -ModuleName M365Health { [pscustomobject]@{ TenantId = '9188040d-6c67-4c5b-b112-36a304b66dad' } }
        Mock Invoke-GraphCollection -ModuleName M365Health { }
        { Get-M365TenantSnapshot -NoPremium } | Should -Throw '*-TenantId*'
        Should -Invoke Invoke-GraphCollection -ModuleName M365Health -Times 0 -Exactly
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

Describe 'Get-M365TenantSnapshot -NoPremium (Entra ID Free)' {
    BeforeAll {
        Mock Get-MgContext -ModuleName M365Health { [pscustomobject]@{ TenantId = 'test' } }
        Mock Invoke-GraphCollection -ModuleName M365Health -ParameterFilter { $Uri -like 'v1.0/users?*' } {
            [pscustomobject]@{ id = 'u-admin'; userPrincipalName = 'admin@contoso.test'; userType = 'Member'; accountEnabled = $true }
            [pscustomobject]@{ id = 'u-mfa'; userPrincipalName = 'mfa@contoso.test'; userType = 'Member'; accountEnabled = $true }
            [pscustomobject]@{ id = 'u-off'; userPrincipalName = 'off@contoso.test'; userType = 'Member'; accountEnabled = $false }
        }
        Mock Invoke-GraphCollection -ModuleName M365Health -ParameterFilter { $Uri -like '*roleAssignments*' } {
            [pscustomobject]@{ principalId = 'u-admin' }
        }
        Mock Invoke-GraphCollection -ModuleName M365Health -ParameterFilter { $Uri -eq 'v1.0/users/u-admin/authentication/methods' } {
            [pscustomobject]@{ '@odata.type' = '#microsoft.graph.passwordAuthenticationMethod' }
        }
        Mock Invoke-GraphCollection -ModuleName M365Health -ParameterFilter { $Uri -eq 'v1.0/users/u-mfa/authentication/methods' } {
            [pscustomobject]@{ '@odata.type' = '#microsoft.graph.passwordAuthenticationMethod' }
            [pscustomobject]@{ '@odata.type' = '#microsoft.graph.microsoftAuthenticatorAuthenticationMethod' }
        }
        Mock Invoke-GraphCollection -ModuleName M365Health -ParameterFilter { $Uri -eq 'v1.0/subscribedSkus' } { }

        $result = Get-M365TenantSnapshot -NoPremium
        $rowFor = { param($id) $result.RegistrationDetails | Where-Object id -EQ $id }
    }

    It 'does not ask for sign-in activity, and says so in the snapshot' {
        Should -Invoke Invoke-GraphCollection -ModuleName M365Health -Times 0 -ParameterFilter { $Uri -like '*signInActivity*' }
        $result.SignInActivityAvailable | Should -BeFalse
        $result.Source | Should -Be 'AuthenticationMethods'
    }

    It 'marks users with an MFA method as registered and password-only users as not' {
        (& $rowFor 'u-mfa').isMfaRegistered | Should -BeTrue
        (& $rowFor 'u-admin').isMfaRegistered | Should -BeFalse
    }

    It 'finds admins through directory role assignments' {
        (& $rowFor 'u-admin').isAdmin | Should -BeTrue
        (& $rowFor 'u-mfa').isAdmin | Should -BeFalse
    }

    It 'does not spend requests on disabled accounts' {
        Should -Invoke Invoke-GraphCollection -ModuleName M365Health -Times 0 -ParameterFilter { $Uri -like 'v1.0/users/u-off/*' }
        & $rowFor 'u-off' | Should -BeNullOrEmpty
    }
}

Describe 'Get-M365TenantSnapshot on a tenant without P1/P2' {
    It 'explains that -NoPremium is needed' {
        Mock Get-MgContext -ModuleName M365Health { [pscustomobject]@{ TenantId = 'test' } }
        Mock Invoke-GraphCollection -ModuleName M365Health {
            throw "Neither tenant is B2C or tenant doesn't have premium license"
        }
        { Get-M365TenantSnapshot } | Should -Throw '*-NoPremium*'
    }

    It 'passes other errors through unchanged' {
        Mock Get-MgContext -ModuleName M365Health { [pscustomobject]@{ TenantId = 'test' } }
        Mock Invoke-GraphCollection -ModuleName M365Health { throw 'Insufficient privileges to complete the operation.' }
        { Get-M365TenantSnapshot } | Should -Throw 'Insufficient privileges*'
    }
}

Describe 'ConvertTo-RegistrationDetail' {
    It 'treats <Type> as <Expected>' -ForEach @(
        @{ Type = 'microsoftAuthenticatorAuthenticationMethod'; Expected = 'MFA' }
        @{ Type = 'phoneAuthenticationMethod'; Expected = 'MFA' }
        @{ Type = 'fido2AuthenticationMethod'; Expected = 'MFA' }
        @{ Type = 'softwareOathAuthenticationMethod'; Expected = 'MFA' }
        @{ Type = 'windowsHelloForBusinessAuthenticationMethod'; Expected = 'MFA' }
        @{ Type = 'passwordAuthenticationMethod'; Expected = 'not MFA' }
        @{ Type = 'emailAuthenticationMethod'; Expected = 'not MFA' }
        @{ Type = 'temporaryAccessPassAuthenticationMethod'; Expected = 'not MFA' }
    ) {
        $row = InModuleScope M365Health -Parameters @{ Type = $Type } {
            param($Type)
            ConvertTo-RegistrationDetail -User ([pscustomobject]@{ id = '1' }) -Methods @(
                [pscustomobject]@{ '@odata.type' = "#microsoft.graph.$Type" }
            )
        }
        $row.isMfaRegistered | Should -Be ($Expected -eq 'MFA')
    }

    It 'lists methods by short name' {
        $row = InModuleScope M365Health {
            ConvertTo-RegistrationDetail -User ([pscustomobject]@{ id = '1' }) -Methods @(
                [pscustomobject]@{ '@odata.type' = '#microsoft.graph.passwordAuthenticationMethod' }
                [pscustomobject]@{ '@odata.type' = '#microsoft.graph.fido2AuthenticationMethod' }
            )
        }
        $row.methodsRegistered | Should -Be @('password', 'fido2')
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
