function New-HealthFinding {
    <#
    .SYNOPSIS
        Builds one finding in the shape every check returns, so reports and exit codes treat them alike.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory object; changes no state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Check,

        [Parameter(Mandatory)]
        [ValidateSet('High', 'Medium', 'Low')]
        [string]$Severity,

        [Parameter(Mandatory)]
        [string]$Target,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$DisplayName,

        [Parameter(Mandatory)]
        [string]$Detail
    )

    [pscustomobject]@{
        PSTypeName  = 'M365Health.Finding'
        Severity    = $Severity
        Check       = $Check
        Target      = $Target
        DisplayName = $DisplayName
        Detail      = $Detail
    }
}
