BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/M365Health/M365Health.psd1') -Force
    $snapshot = Get-Content (Join-Path $PSScriptRoot 'fixtures/snapshot.json') -Raw | ConvertFrom-Json
    $findings = @(Find-UnregisteredMfaUser -Users $snapshot.users -RegistrationDetails $snapshot.registrationDetails)

    function Get-FindingFor([string]$Upn) {
        $findings | Where-Object Target -EQ $Upn
    }
}

Describe 'Find-UnregisteredMfaUser' {
    It 'flags an administrator without MFA as High' {
        $finding = Get-FindingFor 'hank.helpdesk@contoso.test'
        $finding.Check | Should -Be 'MfaNotRegistered'
        $finding.Severity | Should -Be 'High'
    }

    It 'flags <Upn> (member without MFA) as Medium' -ForEach @(
        @{ Upn = 'bob.member@contoso.test' }
        @{ Upn = 'erin.neverused@contoso.test' }
        @{ Upn = 'frank.newhire@contoso.test' }
    ) {
        $finding = Get-FindingFor $Upn
        $finding.Check | Should -Be 'MfaNotRegistered'
        $finding.Severity | Should -Be 'Medium'
    }

    It 'does not flag <Upn>, who registered MFA' -ForEach @(
        @{ Upn = 'ada.admin@contoso.test' }
        @{ Upn = 'carol.dormant@contoso.test' }
        @{ Upn = 'ivy.service@contoso.test' }
    ) {
        Get-FindingFor $Upn | Should -BeNullOrEmpty
    }

    It 'skips disabled accounts, which cannot sign in' {
        Get-FindingFor 'dave.leaver@contoso.test' | Should -BeNullOrEmpty
    }

    It 'skips guests by default' {
        Get-FindingFor 'gina_partner.test#EXT#@contoso.test' | Should -BeNullOrEmpty
    }

    It 'includes guests with -IncludeGuests' {
        $withGuests = Find-UnregisteredMfaUser -Users $snapshot.users -RegistrationDetails $snapshot.registrationDetails -IncludeGuests
        $withGuests.Target | Should -Contain 'gina_partner.test#EXT#@contoso.test'
    }

    It 'reports an account missing from the registration report as Low / MfaStatusUnknown' {
        $finding = Get-FindingFor 'jack.justcreated@contoso.test'
        $finding.Check | Should -Be 'MfaStatusUnknown'
        $finding.Severity | Should -Be 'Low'
    }

    It 'returns exactly the expected set for the fixture tenant' {
        $findings.Count | Should -Be 5
    }

    It 'returns nothing for an empty tenant' {
        Find-UnregisteredMfaUser -Users @() -RegistrationDetails @() | Should -BeNullOrEmpty
    }
}
