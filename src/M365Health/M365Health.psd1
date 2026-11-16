@{
    RootModule        = 'M365Health.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b6a0f0d2-6a3e-4c1e-9a55-1f2d3c4b5a69'
    Author            = 'Ming'
    Description       = 'Read-only Microsoft 365 / Entra ID health checks over Microsoft Graph: accounts without MFA and idle licenses.'
    PowerShellVersion = '7.2'

    # Microsoft.Graph.Authentication is only needed for live runs (Get-M365TenantSnapshot),
    # so it is deliberately not a RequiredModule: tests and fixture-based runs work without it.

    FunctionsToExport = @(
        'Get-M365TenantSnapshot'
        'Find-UnregisteredMfaUser'
        'Find-IdleLicense'
        'Invoke-M365HealthCheck'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData       = @{
        PSData = @{
            Tags = @('Microsoft365', 'EntraID', 'MicrosoftGraph', 'MFA', 'Licensing', 'Reporting')
        }
    }
}
