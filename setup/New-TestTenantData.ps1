#Requires -Version 7.2
<#
.SYNOPSIS
    Seeds an empty lab tenant with test users that trigger every check. Lab tenants only.
.DESCRIPTION
    Unlike the health check this script WRITES to the tenant, so it lives apart from the module and
    supports -WhatIf. It reconciles rather than just creates: every run brings each test user to the
    planned state (exists, licensed, admin role, disabled), so a run that failed halfway is repaired
    by running it again, and a second run changes nothing.

      alex.admin    licensed, Helpdesk Administrator, no MFA   -> MfaNotRegistered (High)
      bella.member  licensed, no MFA                           -> MfaNotRegistered (Medium)
      chris.member  licensed, register MFA yourself            -> clean once registered
      dana.leaver   licensed, then disabled                    -> LicensedDisabledAccount
      eva.member    licensed, register MFA yourself            -> clean once registered
      finn.member   unlicensed                                 -> MfaNotRegistered only

    Plus UnassignedLicenses for the seats left over. Inactivity checks need 90 days of history, which a
    new tenant does not have; the test fixtures cover those, or run with -InactiveDays 1 after a sign-in.

    Without a paid license (Entra ID Free) pass -NoLicense: users and the admin role are still created,
    so the MFA checks work with ./run.ps1 -Connect -NoPremium.
.PARAMETER Domain
    Your tenant's default domain, e.g. yourname.onmicrosoft.com.
.PARAMETER SkuPartNumber
    The license to hand out. AAD_PREMIUM_P2 is what the free Entra ID P2 trial provides.
.PARAMETER NoLicense
    Create the users without assigning any license (for tenants without a paid or trial license).
.EXAMPLE
    ./setup/New-TestTenantData.ps1 -Domain yourname.onmicrosoft.com -WhatIf
.PARAMETER PassThru
    Also output each new account as an object with UserPrincipalName and TemporaryPassword.
.EXAMPLE
    ./setup/New-TestTenantData.ps1 -Domain yourname.onmicrosoft.com -NoLicense
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')]
    [string]$Domain,

    [string]$SkuPartNumber = 'AAD_PREMIUM_P2',

    [switch]$NoLicense,

    # Also output the new accounts as objects. The passwords are always printed, one per line, so a
    # narrow terminal cannot truncate them away the way it truncates a table.
    [switch]$PassThru,

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

# Reads a user by UPN; $null when it does not exist.
function Get-ExistingUser([string]$Upn) {
    try {
        Invoke-MgGraphRequest -Method GET -OutputType PSObject `
            -Uri "v1.0/users/$([uri]::EscapeDataString($Upn))?`$select=id,accountEnabled,assignedLicenses"
    }
    catch {
        if ("$_" -match 'Request_ResourceNotFound|NotFound|\b404\b') { return $null }
        throw
    }
}

function Get-GraphPage([string]$Uri) {
    while ($Uri) {
        $page = Invoke-MgGraphRequest -Method GET -OutputType PSObject -Uri $Uri
        $page.value
        $Uri = $page.'@odata.nextLink'
    }
}

if (-not (Get-Command -Name Connect-MgGraph -ErrorAction SilentlyContinue)) {
    throw 'Microsoft.Graph.Authentication is not installed. Run: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
}
# -TenantId pins the sign-in to the lab tenant. Without it, the owner's personal Microsoft account signs in
# to its own consumer directory, where the directory APIs fail with "not supported for MSA accounts".
Connect-MgGraph -NoWelcome -TenantId $Domain -Scopes 'User.ReadWrite.All', 'Organization.Read.All', 'RoleManagement.ReadWrite.Directory'
$consumerTenantId = '9188040d-6c67-4c5b-b112-36a304b66dad'
if ((Get-MgContext).TenantId -eq $consumerTenantId) {
    throw "Signed in to a personal Microsoft account directory, not to $Domain. Run Disconnect-MgGraph, then run this script again and sign in with an account of $Domain."
}

$skuId = $null
if (-not $NoLicense) {
    $sku = @((Invoke-MgGraphRequest -Method GET -Uri 'v1.0/subscribedSkus' -OutputType PSObject).value) |
        Where-Object skuPartNumber -EQ $SkuPartNumber | Select-Object -First 1
    if (-not $sku) {
        throw "License $SkuPartNumber not found in this tenant. Start the Entra ID P2 trial, or run with -NoLicense to create the users without licenses."
    }
    $skuId = $sku.skuId
}

# A lab tenant has a handful of role assignments, so read them once rather than filtering per user.
$helpdeskAdminIds = @(Get-GraphPage 'v1.0/roleManagement/directory/roleAssignments?$select=principalId,roleDefinitionId' |
        Where-Object roleDefinitionId -EQ $helpdeskAdministratorRoleId |
        ForEach-Object { [string]$_.principalId })

$newAccounts = foreach ($entry in $plan) {
    $upn = "$($entry.Name)@$Domain"
    $user = Get-ExistingUser $upn
    $password = $null

    if ($user) {
        Write-Host "exists    $upn"
    }
    else {
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
        Write-Host "created   $upn"
    }

    $hasLicense = @($user.assignedLicenses | ForEach-Object { [string]$_.skuId }) -contains [string]$skuId
    if ($entry.License -and $skuId -and -not $hasLicense -and $PSCmdlet.ShouldProcess($upn, "Assign $SkuPartNumber")) {
        $null = Invoke-MgGraphRequest -Method POST -Uri "v1.0/users/$($user.id)/assignLicense" -Body @{
            addLicenses    = @(@{ skuId = $skuId; disabledPlans = @() })
            removeLicenses = @()
        }
        Write-Host "licensed  $upn"
    }

    if ($entry.Admin) {
        $hasRole = $helpdeskAdminIds -contains [string]$user.id
        if (-not $hasRole -and $PSCmdlet.ShouldProcess($upn, 'Assign Helpdesk Administrator role')) {
            $null = Invoke-MgGraphRequest -Method POST -Uri 'v1.0/roleManagement/directory/roleAssignments' -Body @{
                principalId      = $user.id
                roleDefinitionId = $helpdeskAdministratorRoleId
                directoryScopeId = '/'
            }
            Write-Host "admin     $upn"
        }
    }

    if ($entry.Disable -and $user.accountEnabled -ne $false -and $PSCmdlet.ShouldProcess($upn, 'Disable account')) {
        $null = Invoke-MgGraphRequest -Method PATCH -Uri "v1.0/users/$($user.id)" -Body @{ accountEnabled = $false }
        Write-Host "disabled  $upn"
    }

    if ($password) {
        [pscustomobject]@{ UserPrincipalName = $upn; TemporaryPassword = $password }
    }
}

if ($newAccounts) {
    Write-Host ''
    Write-Host 'Next: sign in as chris.member and eva.member at https://aka.ms/mysecurityinfo and register Microsoft Authenticator.'
    Write-Host 'Temporary passwords, shown once; each must be changed at first sign-in:'
    foreach ($account in $newAccounts) {
        Write-Host ('  {0}  {1}' -f $account.UserPrincipalName, $account.TemporaryPassword)
    }
}
if ($PassThru) { $newAccounts }
