function Get-M365TenantSnapshot {
    <#
    .SYNOPSIS
        Reads everything the checks need from Microsoft Graph in one pass. Read-only.
    .DESCRIPTION
        Requires an existing Connect-MgGraph session.

        Default (Entra ID P1/P2): reads users with signInActivity and the userRegistrationDetails report.
          Delegated scopes: User.Read.All, AuditLog.Read.All, Organization.Read.All.

        -NoPremium (Entra ID Free): signInActivity and the report are unavailable, so MFA status is built
          from each enabled user's registered authentication methods (one request per user) and admins are
          found through directory role assignments. Inactivity cannot be judged; the snapshot says so and
          Invoke-M365HealthCheck skips those checks.
          Delegated scopes: User.Read.All, UserAuthenticationMethod.Read.All, RoleManagement.Read.Directory,
          Organization.Read.All.

        Either way the signed-in account needs a reader role such as Global Reader. The result can be saved
        with ConvertTo-Json and fed back to Invoke-M365HealthCheck -Snapshot.
    .EXAMPLE
        Connect-MgGraph -Scopes User.Read.All, AuditLog.Read.All, Organization.Read.All
        $snapshot = Get-M365TenantSnapshot
    .EXAMPLE
        Connect-MgGraph -Scopes User.Read.All, UserAuthenticationMethod.Read.All, RoleManagement.Read.Directory, Organization.Read.All
        $snapshot = Get-M365TenantSnapshot -NoPremium
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [switch]$NoPremium
    )

    $hasGraphSdk = [bool](Get-Command -Name Get-MgContext -ErrorAction SilentlyContinue)
    $context = if ($hasGraphSdk) { Get-MgContext }
    if (-not $context) {
        throw 'Not connected to Microsoft Graph. Install Microsoft.Graph.Authentication and run Connect-MgGraph first (see README for the scopes).'
    }
    # The consumer directory of personal Microsoft accounts has no users or licenses to report on.
    if ($context.TenantId -eq '9188040d-6c67-4c5b-b112-36a304b66dad') {
        throw 'Signed in to a personal Microsoft account directory, not a work tenant. Run Disconnect-MgGraph, then connect again with -TenantId <yourtenant>.onmicrosoft.com.'
    }

    $baseFields = 'id,userPrincipalName,displayName,userType,accountEnabled,createdDateTime,assignedLicenses'
    $collectedAt = (Get-Date).ToUniversalTime()

    if ($NoPremium) {
        $users = @(Invoke-GraphCollection -Uri "v1.0/users?`$select=$baseFields")

        $adminIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($assignment in Invoke-GraphCollection -Uri 'v1.0/roleManagement/directory/roleAssignments?$select=principalId') {
            $null = $adminIds.Add([string]$assignment.principalId)
        }

        # Disabled accounts are skipped by the MFA check anyway, so don't spend requests on them.
        $registration = foreach ($user in $users) {
            if ($user.accountEnabled -ne $true) { continue }
            $methods = @(Invoke-GraphCollection -Uri "v1.0/users/$($user.id)/authentication/methods")
            ConvertTo-RegistrationDetail -User $user -Methods $methods -IsAdmin ($adminIds.Contains([string]$user.id))
        }

        return [pscustomobject]@{
            CollectedAt             = $collectedAt
            Source                  = 'AuthenticationMethods'
            SignInActivityAvailable = $false
            Users                   = $users
            RegistrationDetails     = @($registration)
            SubscribedSkus          = @(Invoke-GraphCollection -Uri 'v1.0/subscribedSkus')
        }
    }

    try {
        $users = @(Invoke-GraphCollection -Uri "v1.0/users?`$select=$baseFields,signInActivity")
        $registration = @(Invoke-GraphCollection -Uri 'v1.0/reports/authenticationMethods/userRegistrationDetails')
    }
    catch {
        if ("$_" -match 'premium license') {
            throw "This tenant has no Entra ID P1/P2 license, which sign-in activity and the MFA registration report require. Run again with -NoPremium. Graph said: $_"
        }
        throw
    }

    [pscustomobject]@{
        CollectedAt             = $collectedAt
        Source                  = 'RegistrationReport'
        SignInActivityAvailable = $true
        Users                   = $users
        RegistrationDetails     = $registration
        SubscribedSkus          = @(Invoke-GraphCollection -Uri 'v1.0/subscribedSkus')
    }
}
