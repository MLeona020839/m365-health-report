function Invoke-M365HealthCheck {
    <#
    .SYNOPSIS
        Runs every check and returns the findings, most severe first. Optionally writes CSV and HTML.
    .DESCRIPTION
        Without -Snapshot it reads the connected tenant through Get-M365TenantSnapshot (-NoPremium is
        passed through). With -Snapshot (live or loaded from JSON) it makes no Graph calls at all.

        When the snapshot has no sign-in activity (Entra ID Free), the inactivity checks are skipped
        and the report says so, rather than reporting every licensed account as never signed in.
    .EXAMPLE
        $snapshot = Get-Content ./tests/fixtures/snapshot.json -Raw | ConvertFrom-Json
        Invoke-M365HealthCheck -Snapshot $snapshot -OutputPath ./out
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [object]$Snapshot,

        [ValidateRange(1, 3650)]
        [int]$InactiveDays = 90,

        [switch]$IncludeGuests,

        [switch]$NoPremium,

        [string]$OutputPath
    )

    if ($null -eq $Snapshot) {
        $Snapshot = Get-M365TenantSnapshot -NoPremium:$NoPremium
    }

    $asOf = ConvertTo-UtcDateTime $Snapshot.CollectedAt
    if ($null -eq $asOf) {
        $asOf = (Get-Date).ToUniversalTime()
    }

    # Older snapshots and the fixtures predate this flag; they all contain sign-in activity.
    $signInAvailable = $Snapshot.SignInActivityAvailable -ne $false
    $notes = @()
    if (-not $signInAvailable) {
        $notes += 'Sign-in activity is not available on Entra ID Free, so LicensedInactive and LicensedNeverSignedIn were not checked.'
        Write-Warning $notes[-1]
    }

    $users = @($Snapshot.Users)
    $severityRank = @{ High = 0; Medium = 1; Low = 2 }

    $findings = @(
        @(
            Find-UnregisteredMfaUser -Users $users -RegistrationDetails @($Snapshot.RegistrationDetails) -IncludeGuests:$IncludeGuests
            Find-IdleLicense -Users $users -SubscribedSkus @($Snapshot.SubscribedSkus) -InactiveDays $InactiveDays -AsOf $asOf -SkipSignInChecks:(-not $signInAvailable)
        ) | Sort-Object -Property @{ Expression = { $severityRank[$_.Severity] } }, Check, Target
    )

    if ($OutputPath) {
        $null = New-Item -ItemType Directory -Path $OutputPath -Force
        $csvPath = Join-Path -Path $OutputPath -ChildPath 'm365-health-findings.csv'
        $htmlPath = Join-Path -Path $OutputPath -ChildPath 'm365-health-report.html'

        $findings |
            Select-Object -Property Severity, Check, Target, DisplayName, Detail |
            Export-Csv -Path $csvPath -Encoding utf8
        ConvertTo-HealthReportHtml -Findings $findings -AsOf $asOf -InactiveDays $InactiveDays -Notes $notes |
            Set-Content -Path $htmlPath -Encoding utf8

        Write-Verbose "Wrote $csvPath and $htmlPath"
    }

    $findings
}
