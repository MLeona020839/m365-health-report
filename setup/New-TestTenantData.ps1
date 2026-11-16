#Requires -Version 7.2
#Requires -Modules Microsoft.Graph.Authentication
<#
.SYNOPSIS
    Seeds an empty lab tenant with test users that trigger every check. Lab tenants only.
.DESCRIPTION
    Unlike the health check this script WRITES to the tenant, so it lives apart from the module and
    supports -WhatIf. It is idempotent: users that already exist are left alone.

    It creates six users, assigns the given license to five of them, makes one a Helpdesk Administrator
    and disables one, so a fresh tenant produces High, Medium and Low findings:

      alex.admin    licensed, Helpdesk Administrator, no MFA   -> MfaNotRegistered (High)
      bella.member  licensed, no MFA                           -> MfaNotRegistered (Medium)
      chris.member  licensed, register MFA yourself            -> clean once registered
      dana.leaver   licensed, then disabled                    -> LicensedDisabledAccount
      eva.member    licensed, register MFA yourself            -> clean once registered
      finn.member   unlicensed                                 -> MfaNotRegistered only

    Plus UnassignedLicenses for the seats left over. Inactivity checks need 90 days of history, which a
    new tenant does not have; the test fixtures cover those, or run with -InactiveDays 1 after a sign-in.
.PARAMETER Domain
    Your tenant's default domain, e.g. yourname.onmicrosoft.com.
.PARAMETER SkuPartNumber
    The license to hand out. AAD_PREMIUM_P2 is what the free Entra ID P2 trial provides.
.EXAMPLE
    ./setup/New-TestTenantData.ps1 -Domain yourname.onmicrosoft.com -WhatIf
.EXAMPLE
    ./setup/New-TestTenantData.ps1 -Domain yourname.onmicrosoft.com
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')]
    [string]$Domain,

    [string]$SkuPartNumber = 'AAD_PREMIUM_P2',

    [ValidatePattern('^[A-Z]{2}$')]
    [string]$UsageLocation = 'NL'
)

$ErrorActionPreference = 'Stop'
$helpdeskAdministratorRoleId = '729827e3-9c14-49f7-bb1b-9608f156bbb8'  # built-in role template id

$plan = @(
    @{ Name = 'alex.admin'; DisplayName = 'Alex Admin'; License = $true; Admin = $true; Disable = $false }
    @{ Name = 'bella.member'; DisplayName = 'Bella Member'; License = $true; Admin = $false; Disable = $false }
    @{ Name = 'chris.member'; DisplayName = 'Chris Member'; License = $true; Admin = $false; Disable = $false }
    @{ Name = 'dana.leaver'; DisplayName = 'Dana Leaver'; License = $true; Admin = $false; Disable = $true }
    @{ Name = 'eva.member'; DisplayName = 'Eva Member'; License = $true; Admin = $false; Disable = $false }
    @{ Name = 'finn.member'; DisplayName = 'Finn Member'; License = $false; Admin = $false; Disable = $false }
)

function Get-RandomPassword {
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!#%+=?'
    $chars = 1..20 | ForEach-Object { $alphabet[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($alphabet.Length)] }
    (-join $chars) + 'Aa1!'  # guarantees all four character classes
}

Connect-MgGraph -NoWelcome -Scopes 'User.ReadWrite.All', 'Organization.Read.All', 'RoleManagement.ReadWrite.Directory'

$sku = (Invoke-MgGraphRequest -Method GET -Uri 'v1.0/subscribedSkus' -OutputType PSObject).value |
    Where-Object skuPartNumber -EQ $SkuPartNumber
if (-not $sku) {
    throw "License $SkuPartNumber not found in this tenant. Start the Entra ID P2 trial first (README, step 1)."
}

$created = foreach ($entry in $plan) {
    $upn = "$($entry.Name)@$Domain"
    $existing = (Invoke-MgGraphRequest -Method GET -OutputType PSObject `
            -Uri "v1.0/users?`$filter=userPrincipalName eq '$upn'&`$select=id").value | Select-Object -First 1
    if ($existing) {
        Write-Host "exists   $upn"
        continue
    }
    if (-not $PSCmdlet.ShouldProcess($upn, 'Create test user')) { continue }

    $password = Get-RandomPassword
    $user = Invoke-MgGraphRequest -Method POST -Uri 'v1.0/users' -OutputType PSObject -Body @{
        accountEnabled    = $true
        displayName       = $entry.DisplayName
        mailNickname      = $entry.Name.Replace('.', '')
        userPrincipalName = $upn
        usageLocation     = $UsageLocation
        passwordProfile   = @{ password = $password; forceChangePasswordNextSignIn = $true }
    }
    Write-Host "created  $upn"

    if ($entry.License) {
        $null = Invoke-MgGraphRequest -Method POST -Uri "v1.0/users/$($user.id)/assignLicense" -Body @{
            addLicenses    = @(@{ skuId = $sku.skuId; disabledPlans = @() })
            removeLicenses = @()
        }
    }
    if ($entry.Admin) {
        $null = Invoke-MgGraphRequest -Method POST -Uri 'v1.0/roleManagement/directory/roleAssignments' -Body @{
            principalId      = $user.id
            roleDefinitionId = $helpdeskAdministratorRoleId
            directoryScopeId = '/'
        }
    }
    if ($entry.Disable) {
        $null = Invoke-MgGraphRequest -Method PATCH -Uri "v1.0/users/$($user.id)" -Body @{ accountEnabled = $false }
    }

    [pscustomobject]@{
        UserPrincipalName = $upn
        TemporaryPassword = $password
        Licensed          = $entry.License
        Admin             = $entry.Admin
        Disabled          = $entry.Disable
    }
}

if ($created) {
    Write-Host ''
    Write-Host 'Temporary passwords (shown once; each must be changed at first sign-in):'
    $created | Format-Table -AutoSize | Out-Host
    Write-Host 'Next: sign in as chris.member and eva.member at https://aka.ms/mysecurityinfo and register Microsoft Authenticator.'
}
