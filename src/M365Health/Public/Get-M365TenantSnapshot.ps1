function Get-M365TenantSnapshot {
    <#
    .SYNOPSIS
        Reads everything the checks need from Microsoft Graph in one pass. Read-only.
    .DESCRIPTION
        Requires an existing Connect-MgGraph session. Delegated scopes: User.Read.All, AuditLog.Read.All,
        Organization.Read.All; the signed-in account also needs a reader role such as Global Reader or
        Reports Reader. signInActivity and the registration report need an Entra ID P1 or P2 license.

        The result can be saved with ConvertTo-Json and fed back to Invoke-M365HealthCheck -Snapshot,
        which is how the tests and the offline demo run without a tenant.
    .EXAMPLE
        Connect-MgGraph -Scopes User.Read.All, AuditLog.Read.All, Organization.Read.All
        $snapshot = Get-M365TenantSnapshot
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $hasGraphSdk = [bool](Get-Command -Name Get-MgContext -ErrorAction SilentlyContinue)
    if (-not $hasGraphSdk -or -not (Get-MgContext)) {
        throw 'Not connected to Microsoft Graph. Install Microsoft.Graph.Authentication and run Connect-MgGraph first (see README for the scopes).'
    }

    $userFields = 'id,userPrincipalName,displayName,userType,accountEnabled,createdDateTime,assignedLicenses,signInActivity'

    [pscustomobject]@{
        CollectedAt         = (Get-Date).ToUniversalTime()
        Users               = @(Invoke-GraphCollection -Uri "v1.0/users?`$select=$userFields")
        RegistrationDetails = @(Invoke-GraphCollection -Uri 'v1.0/reports/authenticationMethods/userRegistrationDetails')
        SubscribedSkus      = @(Invoke-GraphCollection -Uri 'v1.0/subscribedSkus')
    }
}
