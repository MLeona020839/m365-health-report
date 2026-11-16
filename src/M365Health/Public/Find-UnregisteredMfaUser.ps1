function Find-UnregisteredMfaUser {
    <#
    .SYNOPSIS
        Finds enabled accounts that have not registered any MFA method.
    .DESCRIPTION
        Pure function over snapshot data; it never calls Graph.

        Severity:
          High    administrator (any admin role) without MFA
          Medium  regular member without MFA
          Low     account missing from the registration report (it refreshes periodically, so new accounts lag)

        Disabled accounts are skipped (they cannot sign in). Guests are skipped unless -IncludeGuests,
        because their MFA is usually enforced by their home tenant.

        "Registered" is not "enforced": whether MFA is actually required at sign-in depends on
        Conditional Access or security defaults, which this check does not evaluate.
    .EXAMPLE
        Find-UnregisteredMfaUser -Users $snapshot.Users -RegistrationDetails $snapshot.RegistrationDetails
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Users,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$RegistrationDetails,

        [switch]$IncludeGuests
    )

    $registrationById = @{}
    foreach ($row in $RegistrationDetails) {
        $registrationById[[string]$row.id] = $row
    }

    foreach ($user in $Users) {
        if ($user.accountEnabled -ne $true) { continue }
        if ($user.userType -eq 'Guest' -and -not $IncludeGuests) { continue }

        $common = @{
            Target      = $user.userPrincipalName
            DisplayName = $user.displayName
        }

        $registration = $registrationById[[string]$user.id]
        if ($null -eq $registration) {
            New-HealthFinding @common -Check 'MfaStatusUnknown' -Severity Low `
                -Detail 'Not in the MFA registration report yet; the report refreshes periodically, so this is common for new accounts.'
            continue
        }

        if ($registration.isMfaRegistered -eq $true) { continue }

        if ($registration.isAdmin -eq $true) {
            New-HealthFinding @common -Check 'MfaNotRegistered' -Severity High `
                -Detail 'Administrator without a registered MFA method.'
        }
        else {
            New-HealthFinding @common -Check 'MfaNotRegistered' -Severity Medium `
                -Detail 'No MFA method registered.'
        }
    }
}
