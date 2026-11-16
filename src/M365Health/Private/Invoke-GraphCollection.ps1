function Invoke-GraphCollection {
    <#
    .SYNOPSIS
        GETs a Microsoft Graph collection and emits every item, following @odata.nextLink across pages.
    .DESCRIPTION
        The only place in the module that talks to Graph. Throttling (HTTP 429 with Retry-After) is
        retried by the Graph SDK's built-in retry handler, so this function only has to handle paging.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Uri
    )

    $next = $Uri
    while ($next) {
        Write-Verbose "GET $next"
        $page = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType PSObject -ErrorAction Stop
        foreach ($item in $page.value) {
            $item
        }
        $next = $page.'@odata.nextLink'
    }
}
