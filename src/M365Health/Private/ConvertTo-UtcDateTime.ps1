function ConvertTo-UtcDateTime {
    <#
    .SYNOPSIS
        Normalises a Graph timestamp (ISO string, DateTime or DateTimeOffset) to a UTC DateTime.
    .DESCRIPTION
        Data reaches the checks in different shapes: Invoke-MgGraphRequest, ConvertFrom-Json and
        hand-built test objects do not agree on whether a timestamp is a string or a DateTime.
        Returns $null for empty input. Timestamps without a zone are treated as UTC, which is what Graph returns.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [object]$Value
    )

    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) { return $null }

    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [System.DateTimeKind]::Unspecified) {
            return [datetime]::SpecifyKind($Value, [System.DateTimeKind]::Utc)
        }
        return $Value.ToUniversalTime()
    }

    [datetimeoffset]::Parse(
        [string]$Value,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal
    ).UtcDateTime
}
