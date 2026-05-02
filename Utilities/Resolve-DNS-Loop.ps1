<#
.SYNOPSIS
    Continuously resolves a DNS name against specific nameservers and outputs timestamped results.

.DESCRIPTION
    Polls one or more DNS names against a configurable list of nameservers at a set
    interval. Results are written to the pipeline (enabling Export-Csv piping) and
    optionally appended to a CSV file directly. Use Ctrl+C to stop, or pass -RunOnce
    to execute a single pass.

.PARAMETER Domains
    One or more DNS names to resolve. Default: 'example.com'

.PARAMETER Servers
    DNS servers to query. Default: Google Public DNS (8.8.8.8, 8.8.4.4)

.PARAMETER IntervalSeconds
    Seconds to wait between resolution rounds. Default: 5

.PARAMETER OutputCsv
    Optional path to a CSV file. Results are appended with -NoTypeInformation.

.PARAMETER RunOnce
    If set, runs one pass and exits instead of looping continuously.

.EXAMPLE
    .\Resolve-DNS-Loop.ps1

.EXAMPLE
    .\Resolve-DNS-Loop.ps1 -Domains 'contoso.com','mail.contoso.com' -IntervalSeconds 10 -OutputCsv .\dns_log.csv

.EXAMPLE
    .\Resolve-DNS-Loop.ps1 -RunOnce | Format-Table
#>

[CmdletBinding()]
param(
    [string[]]$Domains         = @('example.com'),
    [string[]]$Servers         = @('8.8.8.8', '8.8.4.4'),
    [int]$IntervalSeconds      = 5,
    [string]$OutputCsv         = '',
    [switch]$RunOnce
)

function Invoke-DnsQuery {
    param(
        [string]$Domain,
        [string]$Server
    )

    $timestamp = Get-Date -Format 'dd-MMM-yyyy HH:mm:ss'
    $result    = Resolve-DnsName -QuickTimeout -Name $Domain -Server $Server -Type A -ErrorAction SilentlyContinue

    [PSCustomObject]@{
        Timestamp = $timestamp
        Server    = $Server
        Domain    = $Domain
        IP        = if ($result.IPAddress) { $result.IPAddress -join ', ' } else { 'FAIL' }
    }
}

do {
    foreach ($domain in $Domains) {
        foreach ($server in $Servers) {
            $entry = Invoke-DnsQuery -Domain $domain -Server $server

            # Write to pipeline so callers can pipe to Export-Csv, Out-GridView, etc.
            Write-Output $entry

            if ($OutputCsv) {
                $entry | Export-Csv -Path $OutputCsv -Append -NoTypeInformation
            }
        }
    }

    if (-not $RunOnce) {
        Start-Sleep -Seconds $IntervalSeconds
    }

} while (-not $RunOnce)
