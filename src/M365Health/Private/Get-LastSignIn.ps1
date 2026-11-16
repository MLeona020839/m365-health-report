function Get-LastSignIn {
    <#
    .SYNOPSIS
        Returns the most meaningful "last used" timestamp from a user's signInActivity, or $null.
    .DESCRIPTION
        lastSuccessfulSignInDateTime is preferred: lastSignInDateTime also counts failed attempts,
        so an attacker spraying passwords at a dormant account would otherwise make it look active.
        lastSuccessfulSignInDateTime is only populated for sign-ins since December 2023, so when it
        is missing we fall back to the newer of the interactive and non-interactive timestamps.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$SignInActivity
    )

    if ($null -eq $SignInActivity) { return $null }

    $successful = ConvertTo-UtcDateTime $SignInActivity.lastSuccessfulSignInDateTime
    if ($null -ne $successful) { return $successful }

    $candidates = @(
        ConvertTo-UtcDateTime $SignInActivity.lastSignInDateTime
        ConvertTo-UtcDateTime $SignInActivity.lastNonInteractiveSignInDateTime
    ) | Where-Object { $null -ne $_ }

    $candidates | Sort-Object -Descending | Select-Object -First 1
}
