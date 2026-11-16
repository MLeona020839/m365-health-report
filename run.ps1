#Requires -Version 7.2
<#
.SYNOPSIS
    Runs the Microsoft 365 health check and writes a CSV + HTML report.
.DESCRIPTION
    Two modes:
      -SnapshotPath  read a saved snapshot (no tenant, no Graph SDK needed) - used for the demo and in CI
      -Connect       sign in interactively and read the live tenant (read-only scopes)
                     add -NoPremium on Entra ID Free (no P1/P2): MFA is read per user, inactivity is skipped
    Exits with code 1 when a finding reaches -FailOn, so the script can gate a scheduled pipeline.
.EXAMPLE
    ./run.ps1 -SnapshotPath ./tests/fixtures/snapshot.json
.EXAMPLE
    ./run.ps1 -Connect -FailOn High
.EXAMPLE
    ./run.ps1 -Connect -NoPremium
.EXAMPLE
    ./run.ps1 -Connect -SaveSnapshotPath ./out/tenant.snapshot.json
#>
[CmdletBinding(DefaultParameterSetName = 'Live')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Offline')]
    [string]$SnapshotPath,

    [Parameter(ParameterSetName = 'Live')]
    [switch]$Connect,

    [Parameter(ParameterSetName = 'Live')]
    [switch]$NoPremium,

    [Parameter(ParameterSetName = 'Live')]
    [string]$SaveSnapshotPath,

    [ValidateRange(1, 3650)]
    [int]$InactiveDays = 90,

    [switch]$IncludeGuests,

    [string]$OutputPath = './out',

    [ValidateSet('High', 'Medium', 'Low', 'None')]
    [string]$FailOn = 'None'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src/M365Health/M365Health.psd1') -Force

if ($PSCmdlet.ParameterSetName -eq 'Offline') {
    $snapshot = Get-Content -Path $SnapshotPath -Raw | ConvertFrom-Json
}
else {
    if ($Connect) {
        Import-Module Microsoft.Graph.Authentication
        $scopes = if ($NoPremium) {
            'User.Read.All', 'UserAuthenticationMethod.Read.All', 'RoleManagement.Read.Directory', 'Organization.Read.All'
        }
        else {
            'User.Read.All', 'AuditLog.Read.All', 'Organization.Read.All'
        }
        Connect-MgGraph -Scopes $scopes -NoWelcome
    }
    $snapshot = Get-M365TenantSnapshot -NoPremium:$NoPremium
    if ($SaveSnapshotPath) {
        # Contains real names and addresses: keep it out of git (out/ and *.snapshot.json are ignored).
        $snapshot | ConvertTo-Json -Depth 10 | Set-Content -Path $SaveSnapshotPath -Encoding utf8
        Write-Host "Snapshot saved to $SaveSnapshotPath"
    }
}

$findings = @(Invoke-M365HealthCheck -Snapshot $snapshot -InactiveDays $InactiveDays -IncludeGuests:$IncludeGuests -OutputPath $OutputPath)

$findings | Format-Table -Property Severity, Check, Target, Detail -AutoSize -Wrap | Out-Host
Write-Host ('{0} finding(s). Report: {1}' -f $findings.Count, (Join-Path $OutputPath 'm365-health-report.html'))

$rank = @{ Low = 1; Medium = 2; High = 3 }
if ($FailOn -ne 'None') {
    $blocking = @($findings | Where-Object { $rank[$_.Severity] -ge $rank[$FailOn] })
    if ($blocking.Count -gt 0) {
        Write-Host "$($blocking.Count) finding(s) at or above $FailOn."
        exit 1
    }
}
