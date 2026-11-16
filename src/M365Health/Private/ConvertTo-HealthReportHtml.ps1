function ConvertTo-HealthReportHtml {
    <#
    .SYNOPSIS
        Renders findings as a self-contained HTML page. Every tenant-supplied value is HTML-encoded,
        because display names are user-controlled and the report is opened in a browser.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Findings,

        [Parameter(Mandatory)]
        [datetime]$AsOf,

        [Parameter(Mandatory)]
        [int]$InactiveDays
    )

    function Get-Encoded([object]$Value) {
        [System.Net.WebUtility]::HtmlEncode([string]$Value)
    }

    $count = @{ High = 0; Medium = 0; Low = 0 }
    foreach ($finding in $Findings) { $count[$finding.Severity]++ }

    $rows = foreach ($finding in $Findings) {
        $severity = Get-Encoded $finding.Severity
        @"
      <tr>
        <td><span class="badge $($severity.ToLowerInvariant())">$severity</span></td>
        <td><code>$(Get-Encoded $finding.Check)</code></td>
        <td>$(Get-Encoded $finding.Target)</td>
        <td>$(Get-Encoded $finding.DisplayName)</td>
        <td>$(Get-Encoded $finding.Detail)</td>
      </tr>
"@
    }
    if (-not $rows) {
        $rows = '      <tr><td colspan="5" class="empty">No findings.</td></tr>'
    }

    $generated = $AsOf.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)

    @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Microsoft 365 health report</title>
<style>
  :root { --bg: #f7f7f8; --card: #ffffff; --text: #1d1d1f; --muted: #6b6b73; --line: #e3e3e8;
          --high: #c62828; --medium: #b26a00; --low: #2e6db4; }
  @media (prefers-color-scheme: dark) {
    :root { --bg: #151517; --card: #1f1f23; --text: #ececf1; --muted: #a0a0aa; --line: #34343b;
            --high: #ff6b6b; --medium: #f0a63a; --low: #6ea8ff; }
  }
  body { margin: 0; padding: 24px 16px; background: var(--bg); color: var(--text);
         font: 14px/1.5 -apple-system, "Segoe UI", Roboto, sans-serif; }
  main { max-width: 1100px; margin: 0 auto; }
  h1 { font-size: 22px; margin: 0 0 4px; }
  .meta { color: var(--muted); margin: 0 0 20px; }
  .summary { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 12px; margin-bottom: 20px; }
  .tile { background: var(--card); border: 1px solid var(--line); border-radius: 8px; padding: 12px 16px; }
  .tile b { display: block; font-size: 26px; }
  .tile.high b { color: var(--high); } .tile.medium b { color: var(--medium); } .tile.low b { color: var(--low); }
  .table-wrap { overflow-x: auto; background: var(--card); border: 1px solid var(--line); border-radius: 8px; }
  table { border-collapse: collapse; width: 100%; }
  th, td { text-align: left; padding: 8px 12px; border-bottom: 1px solid var(--line); vertical-align: top; }
  th { color: var(--muted); font-weight: 600; }
  tr:last-child td { border-bottom: 0; }
  .badge { font-weight: 600; }
  .badge.high { color: var(--high); } .badge.medium { color: var(--medium); } .badge.low { color: var(--low); }
  .empty { color: var(--muted); text-align: center; padding: 24px; }
  code { font-size: 12px; }
</style>
</head>
<body>
<main>
  <h1>Microsoft 365 health report</h1>
  <p class="meta">Data collected $generated UTC &middot; inactivity threshold $InactiveDays days &middot; $($Findings.Count) finding(s)</p>
  <section class="summary">
    <div class="tile high"><b>$($count.High)</b>High</div>
    <div class="tile medium"><b>$($count.Medium)</b>Medium</div>
    <div class="tile low"><b>$($count.Low)</b>Low</div>
  </section>
  <div class="table-wrap">
    <table>
      <thead><tr><th>Severity</th><th>Check</th><th>Target</th><th>Display name</th><th>Detail</th></tr></thead>
      <tbody>
$($rows -join [Environment]::NewLine)
      </tbody>
    </table>
  </div>
</main>
</body>
</html>
"@
}
