function ConvertTo-RegistrationDetail {
    <#
    .SYNOPSIS
        Builds a row shaped like the userRegistrationDetails report from one user's authentication methods.
    .DESCRIPTION
        Used on Entra ID Free, where the registration report is unavailable. Producing the same shape
        means the MFA check itself does not need to know which source the data came from.

        Password, email (self-service password reset only) and Temporary Access Pass are not MFA methods.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object]$User,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Methods,

        [bool]$IsAdmin
    )

    $mfaMethodTypes = @(
        'microsoftAuthenticatorAuthenticationMethod'
        'phoneAuthenticationMethod'
        'fido2AuthenticationMethod'
        'softwareOathAuthenticationMethod'
        'hardwareOathAuthenticationMethod'
        'windowsHelloForBusinessAuthenticationMethod'
        'platformCredentialAuthenticationMethod'
        'x509CertificateAuthenticationMethod'
    )

    $types = @($Methods | ForEach-Object { ([string]$_.'@odata.type') -replace '^#microsoft\.graph\.', '' })
    $mfaTypes = @($types | Where-Object { $_ -in $mfaMethodTypes })

    [pscustomobject]@{
        id                = $User.id
        userPrincipalName = $User.userPrincipalName
        userDisplayName   = $User.displayName
        userType          = $User.userType
        isAdmin           = $IsAdmin
        isMfaRegistered   = $mfaTypes.Count -gt 0
        methodsRegistered = @($types | ForEach-Object { $_ -replace 'AuthenticationMethod$', '' })
    }
}
