#requires -version 2


<#
.DESCRIPTION
  Queries TLS/SCHANNEL protocol settings and .NET Framework cryptography registry
  keys on one or more remote servers using a single WinRM round-trip per server.
  Checks:
    - .NET Framework v2 SystemDefaultTlsVersions (32-bit & 64-bit)
    - .NET Framework v4 SchUseStrongCrypto (32-bit & 64-bit)
    - SCHANNEL TLS 1.0 / 1.1 / 1.2 Client & Server (DisabledByDefault, Enabled)
    - WinHTTP DefaultSecureProtocols (32-bit & 64-bit)

.PARAMETER Servers
    One or more server names or IP addresses to query. Default: current machine.

.INPUTS
  None

.OUTPUTS
  Formatted tables written to the console. Log file stored in C:\powershell\logs\

.NOTES
  Version:        1.1
  Author:         Pete Baxter
  Creation Date:  2018-07-18
  Purpose/Change: Added -Servers param; consolidated Invoke-Command calls.

.EXAMPLE
  .\Get-TLS-Settings.ps1 -Servers MyServer01

.EXAMPLE
  .\Get-TLS-Settings.ps1 -Servers Server01, Server02, Server03

.EXAMPLE
  # Read server list from a text file
  .\Get-TLS-Settings.ps1 -Servers (Get-Content C:\servers.txt)
#>

param(
    [Parameter(Mandatory = $false)]
    [string[]]$Servers = @($env:COMPUTERNAME)
)

#region---------------------------------------------------------[Initializations]--------------------------------------------------------

#Set Error Action to Silently Continue
$ErrorActionPreference = "SilentlyContinue"

#Dot Source required Function Libraries
Import-Module .\Logging_Functions.psm1 -AsCustomObject -Force -DisableNameChecking

#endregion

#----------------------------------------------------------[Declarations]----------------------------------------------------------

#Script Version
$sScriptVersion = "1.1"

#Log File Info
$sLogPath = "C:\powershell\logs"
$sLogName = "$($MyInvocation.MyCommand.Name)-Log-{0}.log" -f [DateTime]::Now.ToString("yyyy-MM-dd_HH-mm-ss")
$sLogFile = $sLogPath + "\" + $sLogName

#-----------------------------------------------------------[Execution]------------------------------------------------------------

# Create Log File
Log-Start -LogPath $sLogPath -LogName $sLogName -ScriptVersion $sScriptVersion
Log-Write -LogPath $sLogFile -LineValue "Querying servers: $($Servers -join ', ')"

# Create the stopwatch and start the count
$stopWatch = New-Object System.Diagnostics.Stopwatch
$stopWatch.Start()

#region-----------------------------------------------------------[Core Script Execution]------------------------------------------------------------

# All registry reads are consolidated into a single Invoke-Command per server,
# reducing round-trips from 6 to 1 and cutting WinRM session overhead.
Invoke-Command -ComputerName $Servers -ScriptBlock {

    # --- .NET Framework v2 — enables TLS 1.2 for .NET 3.5 apps ---
    $net2_64 = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v2.0.50727'             -Name SystemDefaultTlsVersions -ErrorAction SilentlyContinue
    $net2_32 = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v2.0.50727' -Name SystemDefaultTlsVersions -ErrorAction SilentlyContinue

    # --- .NET Framework v4 — enables strong crypto (TLS 1.2) for .NET 4.x apps ---
    $net4_64 = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319'             -Name SchUseStrongCrypto -ErrorAction SilentlyContinue
    $net4_32 = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319' -Name SchUseStrongCrypto -ErrorAction SilentlyContinue

    # --- SCHANNEL TLS protocol registry keys ---
    $schannelBase = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols'
    $tlsKeys = foreach ($proto in 'TLS 1.0','TLS 1.1','TLS 1.2') {
        foreach ($role in 'Client','Server') {
            $path = "$schannelBase\$proto\$role"
            $dbd  = Get-ItemProperty $path -Name DisabledByDefault -ErrorAction SilentlyContinue
            $enab = Get-ItemProperty $path -Name Enabled           -ErrorAction SilentlyContinue
            if ($dbd)  { $dbd  | Add-Member -NotePropertyName Protocol -NotePropertyValue $proto -Force; $dbd  | Add-Member -NotePropertyName Role -NotePropertyValue $role -Force; $dbd }
            if ($enab) { $enab | Add-Member -NotePropertyName Protocol -NotePropertyValue $proto -Force; $enab | Add-Member -NotePropertyName Role -NotePropertyValue $role -Force; $enab }
        }
    }

    # --- WinHTTP — enables TLS 1.2 for WinHTTP-based components ---
    $wh_64 = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp'             -Name DefaultSecureProtocols -ErrorAction SilentlyContinue
    $wh_32 = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp' -Name DefaultSecureProtocols -ErrorAction SilentlyContinue

    # Return a structured object so all results come back in one round-trip
    [PSCustomObject]@{
        Net2  = @($net2_64, $net2_32) | Where-Object { $_ }
        Net4  = @($net4_64, $net4_32) | Where-Object { $_ }
        TLS   = $tlsKeys
        WinHttp = @($wh_64, $wh_32)  | Where-Object { $_ }
    }

} | ForEach-Object {
    $computer = $_.PSComputerName
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host " Server: $computer" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    Write-Host "`n--- .NET v2 SystemDefaultTlsVersions (should be 1) ---"
    $_.Net2 | Select-Object PSPath, SystemDefaultTlsVersions | Format-Table -AutoSize

    Write-Host "--- .NET v4 SchUseStrongCrypto (should be 1) ---"
    $_.Net4 | Select-Object PSPath, SchUseStrongCrypto | Format-Table -AutoSize

    Write-Host "--- SCHANNEL TLS Protocols ---"
    $_.TLS  | Select-Object Protocol, Role, DisabledByDefault, Enabled | Sort-Object Protocol, Role | Format-Table -AutoSize

    Write-Host "--- WinHTTP DefaultSecureProtocols (0xA80 = TLS 1.1+1.2) ---"
    $_.WinHttp | Select-Object PSPath, DefaultSecureProtocols | Format-Table -AutoSize
}

Log-Write -LogPath $sLogFile -LineValue "Registry queries completed for: $($Servers -join ', ')"

#endregion

# Stop the stopwatch and place in variable
$stopWatch.Stop()
$ts = $stopWatch.Elapsed

# Add the elapsed time to the log
Log-Message -Message $("Script Completed in {0} minutes, {1} seconds" -f $ts.Minutes, $ts.Seconds) -LogPath $sLogFile

# Finish log and close out file
Log-Finish -LogPath $sLogFile
