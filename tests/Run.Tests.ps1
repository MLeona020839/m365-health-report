BeforeAll {
    . (Join-Path $PSScriptRoot 'GraphStubs.ps1')
    $script:createdStubs = Add-GraphStubs
    $script:runScript = Join-Path $PSScriptRoot '../run.ps1'
}

AfterAll {
    Remove-GraphStubs $script:createdStubs
}

Describe 'run.ps1 -Connect' {
    BeforeEach {
        Mock Connect-MgGraph {}
    }

    # Connect-MgGraph is mocked, so no session exists and the snapshot stops at "Not connected".
    # That is enough to check how run.ps1 signs in.

    It 'signs in to the given tenant with the Entra ID Free scopes' {
        { & $runScript -Connect -TenantId 'lab.test' -NoPremium -OutputPath (Join-Path $TestDrive 'out') } |
            Should -Throw '*Not connected*'

        Should -Invoke Connect-MgGraph -Times 1 -Exactly -ParameterFilter {
            $TenantId -eq 'lab.test' -and $Scopes -contains 'UserAuthenticationMethod.Read.All' -and $Scopes -notcontains 'AuditLog.Read.All'
        }
    }

    It 'signs in with the P1/P2 scopes, and without a tenant when none is given' {
        { & $runScript -Connect -OutputPath (Join-Path $TestDrive 'out') } | Should -Throw '*Not connected*'

        Should -Invoke Connect-MgGraph -Times 1 -Exactly -ParameterFilter {
            -not $TenantId -and $Scopes -contains 'AuditLog.Read.All'
        }
    }
}

Describe 'run.ps1 -SnapshotPath' {
    It 'exits 1 when a finding reaches -FailOn, and 0 otherwise' {
        $fixture = Join-Path $PSScriptRoot 'fixtures/snapshot.json'
        $pwsh = (Get-Process -Id $PID).Path

        & $pwsh -NoProfile -File $runScript -SnapshotPath $fixture -OutputPath (Join-Path $TestDrive 'a') -FailOn High *> $null
        $LASTEXITCODE | Should -Be 1

        & $pwsh -NoProfile -File $runScript -SnapshotPath $fixture -OutputPath (Join-Path $TestDrive 'b') *> $null
        $LASTEXITCODE | Should -Be 0
    }
}
