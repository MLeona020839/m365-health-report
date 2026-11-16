function Find-IdleLicense {
    <#
    .SYNOPSIS
        Finds licenses that are paid for but not used.
    .DESCRIPTION
        Pure function over snapshot data; it never calls Graph. Four checks:

          UnassignedLicenses       Low     purchased seats assigned to nobody (per SKU)
          LicensedDisabledAccount  Medium  disabled account still holding a license
          LicensedInactive         Medium  no sign-in for more than -InactiveDays
          LicensedNeverSignedIn    Medium  never signed in, and created more than -InactiveDays ago
                                           (newer accounts get a grace period)

        Free self-service SKUs (-IgnoreSkuPartNumber) are skipped because they always show thousands of
        "unassigned" seats. SKUs that are suspended or deleted are skipped as well.

        -SkipSignInChecks drops the two sign-in based checks. Use it when sign-in activity was not
        collected (Entra ID Free); otherwise every licensed account would look like it never signed in.
    .PARAMETER AsOf
        Reference time for inactivity. Defaults to now; Invoke-M365HealthCheck passes the snapshot's
        collection time so that results for a saved snapshot never change.
    .EXAMPLE
        Find-IdleLicense -Users $snapshot.Users -SubscribedSkus $snapshot.SubscribedSkus -InactiveDays 60
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Users,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$SubscribedSkus,

        [ValidateRange(1, 3650)]
        [int]$InactiveDays = 90,

        [datetime]$AsOf = (Get-Date).ToUniversalTime(),

        [string[]]$IgnoreSkuPartNumber = @('FLOW_FREE', 'POWER_BI_STANDARD', 'POWERAPPS_VIRAL', 'WINDOWS_STORE'),

        [switch]$SkipSignInChecks
    )

    $asOfUtc = ConvertTo-UtcDateTime $AsOf
    $cutoff = $asOfUtc.AddDays(-$InactiveDays)
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture

    $skuNameById = @{}
    foreach ($sku in $SubscribedSkus) {
        $skuNameById[[string]$sku.skuId] = $sku.skuPartNumber
    }

    # Seats bought but assigned to nobody.
    foreach ($sku in $SubscribedSkus) {
        if ($sku.skuPartNumber -in $IgnoreSkuPartNumber) { continue }
        if ($sku.capabilityStatus -notin 'Enabled', 'Warning') { continue }

        $total = [int]$sku.prepaidUnits.enabled
        $unassigned = $total - [int]$sku.consumedUnits
        if ($unassigned -gt 0) {
            New-HealthFinding -Check 'UnassignedLicenses' -Severity Low -Target $sku.skuPartNumber `
                -Detail "$unassigned of $total seats are not assigned to anyone."
        }
    }

    # Seats assigned to accounts that are not using them.
    foreach ($user in $Users) {
        $licenses = @($user.assignedLicenses | Where-Object { $null -ne $_ })
        if ($licenses.Count -eq 0) { continue }

        $skuNames = ($licenses | ForEach-Object { $skuNameById[[string]$_.skuId] ?? [string]$_.skuId }) -join ', '
        $common = @{
            Target      = $user.userPrincipalName
            DisplayName = $user.displayName
        }

        if ($user.accountEnabled -ne $true) {
            New-HealthFinding @common -Check 'LicensedDisabledAccount' -Severity Medium `
                -Detail "Account is disabled but still holds: $skuNames."
            continue
        }

        if ($SkipSignInChecks) { continue }

        $lastSignIn = Get-LastSignIn $user.signInActivity
        if ($null -eq $lastSignIn) {
            $created = ConvertTo-UtcDateTime $user.createdDateTime
            if ($null -ne $created -and $created -lt $cutoff) {
                New-HealthFinding @common -Check 'LicensedNeverSignedIn' -Severity Medium `
                    -Detail "Created $($created.ToString('yyyy-MM-dd', $invariant)) and never signed in; holds: $skuNames."
            }
        }
        elseif ($lastSignIn -lt $cutoff) {
            $days = [math]::Floor(($asOfUtc - $lastSignIn).TotalDays)
            New-HealthFinding @common -Check 'LicensedInactive' -Severity Medium `
                -Detail "No sign-in for $days days (last $($lastSignIn.ToString('yyyy-MM-dd', $invariant))); holds: $skuNames."
        }
    }
}
