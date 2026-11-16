BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/M365Health/M365Health.psd1') -Force
    $fixturePath = Join-Path $PSScriptRoot 'fixtures/snapshot.json'
    $snapshot = Get-Content $fixturePath -Raw | ConvertFrom-Json
}

Describe 'Invoke-M365HealthCheck' {
    BeforeAll {
        $findings = @(Invoke-M365HealthCheck -Snapshot $snapshot)
    }

    It 'combines MFA and license findings for the fixture tenant' {
        $findings.Count | Should -Be 9
    }

    It 'sorts the most severe findings first' {
        $findings[0].Severity | Should -Be 'High'
        $findings[-1].Severity | Should -Be 'Low'
    }

    It "uses the snapshot's collection time, so a saved snapshot always gives the same result" {
        # carol last signed in 2026-05-10; measured from today she would be even more inactive,
        # but the detail must still say 174 days (2026-11-01 minus 2026-05-10).
        ($findings | Where-Object Target -EQ 'carol.dormant@contoso.test').Detail | Should -BeLike '*174 days*'
    }

    It 'does not call Graph when a snapshot is passed in' {
        Mock Get-M365TenantSnapshot -ModuleName M365Health { throw 'should not be called' }
        $null = Invoke-M365HealthCheck -Snapshot $snapshot
        Should -Invoke Get-M365TenantSnapshot -ModuleName M365Health -Times 0 -Exactly
    }

    It 'reads the live tenant when no snapshot is passed in' {
        Mock Get-M365TenantSnapshot -ModuleName M365Health { $snapshot }
        (Invoke-M365HealthCheck).Count | Should -Be 9
        Should -Invoke Get-M365TenantSnapshot -ModuleName M365Health -Times 1 -Exactly
    }

    Context 'report files' {
        BeforeAll {
            $out = Join-Path $TestDrive 'report'
            $null = Invoke-M365HealthCheck -Snapshot $snapshot -OutputPath $out
            $csv = @(Import-Csv (Join-Path $out 'm365-health-findings.csv'))
            $html = Get-Content (Join-Path $out 'm365-health-report.html') -Raw
        }

        It 'writes one CSV row per finding' {
            $csv.Count | Should -Be 9
            $csv[0].PSObject.Properties.Name | Should -Be @('Severity', 'Check', 'Target', 'DisplayName', 'Detail')
        }

        It 'writes an HTML report with the summary and every finding' {
            $html | Should -BeLike '*<b>1</b>High*'
            $html | Should -BeLike '*hank.helpdesk@contoso.test*'
            $html | Should -BeLike '*AAD_PREMIUM_P2*'
        }
    }

    It 'HTML-encodes tenant data, since display names are user-controlled' {
        $hostile = [pscustomobject]@{
            CollectedAt         = '2026-11-01T00:00:00Z'
            Users               = @([pscustomobject]@{
                    id = 'x1'; userPrincipalName = 'evil@contoso.test'; displayName = '<script>alert(1)</script>'
                    userType = 'Member'; accountEnabled = $true; createdDateTime = '2026-01-01T00:00:00Z'
                    assignedLicenses = @(); signInActivity = $null
                })
            RegistrationDetails = @([pscustomobject]@{ id = 'x1'; isAdmin = $false; isMfaRegistered = $false })
            SubscribedSkus      = @()
        }
        $out = Join-Path $TestDrive 'hostile'
        $null = Invoke-M365HealthCheck -Snapshot $hostile -OutputPath $out
        $html = Get-Content (Join-Path $out 'm365-health-report.html') -Raw

        $html | Should -Not -BeLike '*<script>alert*'
        $html | Should -BeLike '*&lt;script&gt;alert(1)&lt;/script&gt;*'
    }

    Context 'snapshot from Entra ID Free (no sign-in activity)' {
        BeforeAll {
            $free = $snapshot | ConvertTo-Json -Depth 10 | ConvertFrom-Json
            $free.users | ForEach-Object { $_.signInActivity = $null }
            $free | Add-Member -NotePropertyName SignInActivityAvailable -NotePropertyValue $false
            $out = Join-Path $TestDrive 'free'
            $freeFindings = @(Invoke-M365HealthCheck -Snapshot $free -OutputPath $out -WarningVariable warnings -WarningAction SilentlyContinue)
        }

        It 'does not report every licensed account as never signed in' {
            $freeFindings.Check | Should -Not -Contain 'LicensedNeverSignedIn'
            $freeFindings.Check | Should -Not -Contain 'LicensedInactive'
        }

        It 'still runs the MFA and seat checks' {
            ($freeFindings | Where-Object Check -EQ 'MfaNotRegistered').Count | Should -Be 4
            $freeFindings.Check | Should -Contain 'LicensedDisabledAccount'
        }

        It 'warns, and says in the report which checks were skipped' {
            $warnings | Should -HaveCount 1
            Get-Content (Join-Path $out 'm365-health-report.html') -Raw | Should -BeLike '*class="note"*LicensedInactive*'
        }
    }

    It 'writes a valid report for a healthy tenant' {
        $healthy = [pscustomobject]@{ CollectedAt = '2026-11-01T00:00:00Z'; Users = @(); RegistrationDetails = @(); SubscribedSkus = @() }
        $out = Join-Path $TestDrive 'healthy'
        Invoke-M365HealthCheck -Snapshot $healthy -OutputPath $out | Should -BeNullOrEmpty
        Get-Content (Join-Path $out 'm365-health-report.html') -Raw | Should -BeLike '*No findings.*'
    }
}

Describe 'Fixtures' {
    It 'contain only reserved test domains, never real tenant data' {
        $upns = @($snapshot.users.userPrincipalName) + @($snapshot.registrationDetails.userPrincipalName)
        $upns | ForEach-Object { $_ | Should -Match '@contoso\.test$' }
    }
}
