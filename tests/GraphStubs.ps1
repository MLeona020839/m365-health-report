# Dot-sourced by tests that mock the Microsoft Graph SDK.
#
# The tests run without the SDK installed (CI has no tenant and no SDK), but Pester can only mock commands
# that exist. These empty stand-ins carry the same parameters the code uses, and are removed again by
# Remove-GraphStubs so they never shadow the real SDK in an interactive session.

function Add-GraphStubs {
    $added = @()
    if (-not (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
        function global:Invoke-MgGraphRequest { [CmdletBinding()] param($Method, $Uri, $OutputType, $Body) }
        $added += 'Invoke-MgGraphRequest'
    }
    if (-not (Get-Command Get-MgContext -ErrorAction SilentlyContinue)) {
        function global:Get-MgContext { [CmdletBinding()] param() }
        $added += 'Get-MgContext'
    }
    if (-not (Get-Command Connect-MgGraph -ErrorAction SilentlyContinue)) {
        function global:Connect-MgGraph { [CmdletBinding()] param($Scopes, [switch]$NoWelcome) }
        $added += 'Connect-MgGraph'
    }
    $added
}

function Remove-GraphStubs([string[]]$Name) {
    foreach ($stub in $Name) {
        Remove-Item -Path "Function:\$stub" -ErrorAction SilentlyContinue
    }
}
