BeforeAll {
    . (Join-Path $PSScriptRoot 'GraphStubs.ps1')
    $script:createdStubs = Add-GraphStubs

    $script:setupScript = Join-Path $PSScriptRoot '../setup/New-TestTenantData.ps1'

    # Global on purpose: the mock runs inside the setup script's own script scope, where $script: would
    # point at the setup script instead of this test file.
    function Initialize-FakeTenant {
        param([switch]$WithoutSku, [object[]]$ExistingUsers = @())
        $global:FakeM365Tenant = @{
            Skus   = if ($WithoutSku) { @() } else { @([pscustomobject]@{ skuId = 'sku-p2'; skuPartNumber = 'AAD_PREMIUM_P2' }) }
            Users  = @{}
            Roles  = [System.Collections.Generic.List[object]]::new()
            Writes = [System.Collections.Generic.List[string]]::new()
        }
        foreach ($user in $ExistingUsers) { $global:FakeM365Tenant.Users[$user.userPrincipalName] = $user }
    }

    # A tiny in-memory Graph: enough of /users, /assignLicense, role assignments and PATCH for the script.
    function Invoke-FakeGraph {
        param([string]$Method, [string]$Uri, [object]$Body)
        $t = $global:FakeM365Tenant
        if ($Method -ne 'GET') { $t.Writes.Add("$Method $Uri") }
        $findById = { param($id) $t.Users.Values | Where-Object id -EQ $id }

        switch -Regex ("$Method $Uri") {
            '^GET v1\.0/subscribedSkus$' {
                return [pscustomobject]@{ value = $t.Skus }
            }
            "^GET v1\.0/users/([^/?]+)\?\`$select=" {
                $match = $t.Users[[uri]::UnescapeDataString($Matches[1])]
                if (-not $match) { throw 'Response status code does not indicate success: NotFound (Not Found). Request_ResourceNotFound' }
                return $match
            }
            '^POST v1\.0/users$' {
                $new = [pscustomobject]@{
                    id = "id-$($Body.mailNickname)"; userPrincipalName = $Body.userPrincipalName
                    accountEnabled = $Body.accountEnabled; assignedLicenses = @()
                }
                $t.Users[$new.userPrincipalName] = $new
                return $new
            }
            '^POST v1\.0/users/([^/]+)/assignLicense$' {
                $target = & $findById $Matches[1]
                $target.assignedLicenses = @($Body.addLicenses | ForEach-Object { [pscustomobject]@{ skuId = $_.skuId } })
                return $null
            }
            "^GET v1\.0/roleManagement/directory/roleAssignments\?\`$select=" {
                return [pscustomobject]@{ value = @($t.Roles) }
            }
            '^POST v1\.0/roleManagement/directory/roleAssignments$' {
                $t.Roles.Add([pscustomobject]$Body)
                return $null
            }
            '^PATCH v1\.0/users/(.+)$' {
                (& $findById $Matches[1]).accountEnabled = $Body.accountEnabled
                return $null
            }
            default { throw "Unexpected Graph call: $Method $Uri" }
        }
    }

    function Get-Write([string]$Pattern) {
        @($global:FakeM365Tenant.Writes | Where-Object { $_ -like $Pattern })
    }
}

AfterAll {
    Remove-Variable -Name FakeM365Tenant -Scope Global -ErrorAction SilentlyContinue
    Remove-GraphStubs $script:createdStubs
}

Describe 'setup/New-TestTenantData.ps1' {
    BeforeEach {
        Mock Connect-MgGraph {}
        Mock Get-MgContext { [pscustomobject]@{ TenantId = '11111111-2222-3333-4444-555555555555' } }
        Mock Write-Host {}
        Mock Invoke-MgGraphRequest { Invoke-FakeGraph -Method $Method -Uri $Uri -Body $Body }
    }

    It 'creates the six users, five licenses, one admin role and one disabled account' {
        Initialize-FakeTenant
        $accounts = @(& $setupScript -Domain 'lab.test' -PassThru)

        $accounts.Count | Should -Be 6
        $accounts.TemporaryPassword | ForEach-Object { $_.Length | Should -BeGreaterOrEqual 20 }
        (Get-Write 'POST v1.0/users').Count | Should -Be 6
        (Get-Write 'POST v1.0/users/*/assignLicense').Count | Should -Be 5
        (Get-Write 'POST v1.0/roleManagement/*').Count | Should -Be 1
        $global:FakeM365Tenant.Roles[0].principalId | Should -Be 'id-alexadmin'
        $global:FakeM365Tenant.Users['dana.leaver@lab.test'].accountEnabled | Should -BeFalse
        $global:FakeM365Tenant.Users['finn.member@lab.test'].assignedLicenses | Should -BeNullOrEmpty
    }

    It 'prints each password on its own line, and outputs no objects without -PassThru' {
        Initialize-FakeTenant
        $output = & $setupScript -Domain 'lab.test'

        $output | Should -BeNullOrEmpty
        Should -Invoke Write-Host -Times 6 -Exactly -ParameterFilter { $Object -match '^  \S+@lab\.test  \S{20,}$' }
    }

    It 'changes nothing with -WhatIf' {
        Initialize-FakeTenant
        $null = & $setupScript -Domain 'lab.test' -WhatIf
        $global:FakeM365Tenant.Writes.Count | Should -Be 0
    }

    It 'changes nothing and prints no passwords on a second run' {
        Initialize-FakeTenant
        $null = & $setupScript -Domain 'lab.test'
        $global:FakeM365Tenant.Writes.Clear()

        $accounts = & $setupScript -Domain 'lab.test' -PassThru

        $accounts | Should -BeNullOrEmpty
        $global:FakeM365Tenant.Writes.Count | Should -Be 0
    }

    It 'repairs a half-finished run by licensing a user that already exists' {
        Initialize-FakeTenant -ExistingUsers @(
            [pscustomobject]@{ id = 'id-existing'; userPrincipalName = 'bella.member@lab.test'; accountEnabled = $true; assignedLicenses = @() }
        )
        $accounts = @(& $setupScript -Domain 'lab.test' -PassThru)

        $accounts.UserPrincipalName | Should -Not -Contain 'bella.member@lab.test'
        Get-Write 'POST v1.0/users/id-existing/assignLicense' | Should -HaveCount 1
    }

    It 'creates users without licenses with -NoLicense, even when the tenant has no SKU' {
        Initialize-FakeTenant -WithoutSku
        $accounts = @(& $setupScript -Domain 'lab.test' -NoLicense -PassThru)

        $accounts.Count | Should -Be 6
        Get-Write '*assignLicense' | Should -BeNullOrEmpty
        (Get-Write 'POST v1.0/roleManagement/*').Count | Should -Be 1
    }

    It 'signs in to the tenant named by -Domain, not the account''s home directory' {
        Initialize-FakeTenant
        $null = & $setupScript -Domain 'lab.test' -WhatIf
        Should -Invoke Connect-MgGraph -Times 1 -Exactly -ParameterFilter { $TenantId -eq 'lab.test' }
    }

    It 'stops before touching anything when signed in to a personal Microsoft account directory' {
        Initialize-FakeTenant
        Mock Get-MgContext { [pscustomobject]@{ TenantId = '9188040d-6c67-4c5b-b112-36a304b66dad' } }

        { & $setupScript -Domain 'lab.test' } | Should -Throw '*Disconnect-MgGraph*'
        Should -Invoke Invoke-MgGraphRequest -Times 0 -Exactly
    }

    It 'stops before writing anything, pointing at -NoLicense, when the license is missing' {
        Initialize-FakeTenant -WithoutSku
        { & $setupScript -Domain 'lab.test' } | Should -Throw '*-NoLicense*'
        $global:FakeM365Tenant.Writes.Count | Should -Be 0
    }
}
