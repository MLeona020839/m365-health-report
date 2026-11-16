BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/M365Health/M365Health.psd1') -Force
    $snapshot = Get-Content (Join-Path $PSScriptRoot 'fixtures/snapshot.json') -Raw | ConvertFrom-Json
    $asOf = [datetime]::new(2026, 11, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
    $findings = @(Find-IdleLicense -Users $snapshot.users -SubscribedSkus $snapshot.subscribedSkus -AsOf $asOf)

    function Get-FindingFor([string]$Target) {
        $findings | Where-Object Target -EQ $Target
    }

    function New-TestUser {
        param([string]$Upn, [object]$SignInActivity, [string]$Created = '2025-01-01T00:00:00Z')
        [pscustomobject]@{
            id                = [guid]::NewGuid().ToString()
            userPrincipalName = $Upn
            displayName       = $Upn
            userType          = 'Member'
            accountEnabled    = $true
            createdDateTime   = $Created
            assignedLicenses  = @([pscustomobject]@{ skuId = 'sku-1' })
            signInActivity    = $SignInActivity
        }
    }
}

Describe 'Find-IdleLicense' {
    Context 'unassigned seats' {
        It 'reports purchased seats nobody uses, per SKU' {
            $finding = Get-FindingFor 'AAD_PREMIUM_P2'
            $finding.Check | Should -Be 'UnassignedLicenses'
            $finding.Severity | Should -Be 'Low'
            $finding.Detail | Should -BeLike '92 of 100 seats*'
        }

        It 'ignores free self-service SKUs' {
            Get-FindingFor 'FLOW_FREE' | Should -BeNullOrEmpty
        }

        It 'ignores suspended SKUs' {
            $sku = [pscustomobject]@{
                skuId = 'sku-x'; skuPartNumber = 'ENTERPRISEPACK'; capabilityStatus = 'Suspended'
                consumedUnits = 0; prepaidUnits = [pscustomobject]@{ enabled = 25 }
            }
            Find-IdleLicense -Users @() -SubscribedSkus @($sku) -AsOf $asOf | Should -BeNullOrEmpty
        }

        It 'reports nothing when every seat is assigned' {
            $sku = [pscustomobject]@{
                skuId = 'sku-y'; skuPartNumber = 'SPE_E3'; capabilityStatus = 'Enabled'
                consumedUnits = 10; prepaidUnits = [pscustomobject]@{ enabled = 10 }
            }
            Find-IdleLicense -Users @() -SubscribedSkus @($sku) -AsOf $asOf | Should -BeNullOrEmpty
        }
    }

    Context 'assigned seats' {
        It 'flags a disabled account that still holds a license, naming the SKU' {
            $finding = Get-FindingFor 'dave.leaver@contoso.test'
            $finding.Check | Should -Be 'LicensedDisabledAccount'
            $finding.Detail | Should -BeLike '*AAD_PREMIUM_P2*'
        }

        It 'flags a user with no sign-in for longer than the threshold' {
            $finding = Get-FindingFor 'carol.dormant@contoso.test'
            $finding.Check | Should -Be 'LicensedInactive'
            $finding.Detail | Should -BeLike 'No sign-in for 174 days (last 2026-05-10)*'
        }

        It 'respects -InactiveDays' {
            $relaxed = Find-IdleLicense -Users $snapshot.users -SubscribedSkus $snapshot.subscribedSkus -AsOf $asOf -InactiveDays 200
            $relaxed.Target | Should -Not -Contain 'carol.dormant@contoso.test'
        }

        It 'flags a licensed account that never signed in and is older than the threshold' {
            (Get-FindingFor 'erin.neverused@contoso.test').Check | Should -Be 'LicensedNeverSignedIn'
        }

        It 'gives a new account that has not signed in yet a grace period' {
            Get-FindingFor 'frank.newhire@contoso.test' | Should -BeNullOrEmpty
        }

        It 'counts non-interactive sign-ins as activity' {
            Get-FindingFor 'ivy.service@contoso.test' | Should -BeNullOrEmpty
        }

        It 'never flags unlicensed users' {
            Get-FindingFor 'jack.justcreated@contoso.test' | Should -BeNullOrEmpty
            Get-FindingFor 'gina_partner.test#EXT#@contoso.test' | Should -BeNullOrEmpty
        }

        It 'trusts the last successful sign-in over a recent failed attempt' {
            $user = New-TestUser -Upn 'sprayed@contoso.test' -SignInActivity ([pscustomobject]@{
                    lastSignInDateTime           = '2026-10-31T23:00:00Z'  # failed password-spray attempt
                    lastSuccessfulSignInDateTime = '2026-01-15T09:00:00Z'
                })
            $result = Find-IdleLicense -Users @($user) -SubscribedSkus @() -AsOf $asOf
            $result.Check | Should -Be 'LicensedInactive'
        }

        It 'accepts DateTime values as well as ISO strings' {
            $user = New-TestUser -Upn 'typed@contoso.test' -SignInActivity ([pscustomobject]@{
                    lastSuccessfulSignInDateTime = [datetime]::new(2026, 1, 15, 9, 0, 0, [System.DateTimeKind]::Utc)
                })
            (Find-IdleLicense -Users @($user) -SubscribedSkus @() -AsOf $asOf).Check | Should -Be 'LicensedInactive'
        }

        It 'falls back to the SKU id when the SKU is not in the subscription list' {
            $user = New-TestUser -Upn 'unknown-sku@contoso.test' -SignInActivity $null
            (Find-IdleLicense -Users @($user) -SubscribedSkus @() -AsOf $asOf).Detail | Should -BeLike '*holds: sku-1.'
        }
    }

    It 'returns exactly the expected set for the fixture tenant' {
        $findings.Count | Should -Be 4
    }
}
