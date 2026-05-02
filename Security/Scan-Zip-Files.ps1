#requires -version 5.1
<#
.SYNOPSIS
    Moves ZIP files through a scan pipeline: source → process → Windows Defender scan → complete.

.DESCRIPTION
    Implements a secure three-stage file handling pipeline for ZIP archives:

      Stage 1 — Move:    Moves all *.zip files from a source path to a processing path.
      Stage 2 — Scan:    Runs a Windows Defender custom scan on the processing folder.
                         The script exits immediately if the scan or threat removal fails.
      Stage 3 — Archive: Moves the clean ZIP files from the processing path to a
                         completed/archive path.

    All operations are logged to both the Windows Application Event Log (Source = script
    filename, EventId 7777 = info / 7778 = error) and a local text log file.

    Designed to run as a scheduled task or as part of a file-intake automation pipeline.
    Requires the Windows Defender module (MpCmdRun) — available by default on Windows 10/11
    and Windows Server 2016+.

.PARAMETER sourcePath
    UNC or local path with wildcard pointing to the ZIP files to process.
    Example: C:\intake\incoming\*   or   \\fileserver\drop\*

.PARAMETER moveToPath
    UNC or local path where files are staged for scanning.
    Example: C:\intake\process\

.PARAMETER processPath
    UNC or local path with wildcard pointing to the files after scanning.
    Example: C:\intake\process\*

.PARAMETER completePath
    UNC or local path where clean files are moved after the scan passes.
    Example: C:\intake\complete\

.INPUTS
    ZIP files at $sourcePath. All other inputs are via parameters.

.OUTPUTS
    Log file: .\logs\Scan-Zip-Files-Log-<timestamp>.log
    Windows Application Event Log entries (Source: Scan-Zip-Files.ps1)

.NOTES
    Version:        1.2
    Author:         Pete Baxter
    Creation Date:  2021-06-16
    Purpose/Change: v1.2 — added command-line parameters.
                    v1.1 — added exception handling.
                    v1.0 — initial release.

.EXAMPLE
    .\Scan-Zip-Files.ps1 `
        -sourcePath   'C:\intake\incoming\*' `
        -moveToPath   'C:\intake\process\' `
        -processPath  'C:\intake\process\*' `
        -completePath 'C:\intake\complete\'

    Moves all ZIPs from C:\intake\incoming, scans them, and archives clean files
    to C:\intake\complete.

.EXAMPLE
    # Run from a UNC share — useful for centralised intake from multiple servers
    .\Scan-Zip-Files.ps1 `
        -sourcePath   '\\fileserver\drop\*' `
        -moveToPath   'C:\intake\process\' `
        -processPath  'C:\intake\process\*' `
        -completePath '\\fileserver\archive\'
#>




#region---------------------------------------------------------[Initializations]--------------------------------------------------------

param (
    [Parameter(Mandatory=$true, HelpMessage="Local drive location or UNC path using * to capture all files, ex. - c:\folder\folder\*")]
    $sourcePath,
    [Parameter(Mandatory=$true, HelpMessage="Local drive location or UNC path, ex. - c:\folder\folder\")]
    $moveToPath,
    [Parameter(Mandatory=$true, HelpMessage="Local drive location or UNC path using * to capture all files, ex. - c:\folder\folder\*")]
    $processPath,
    [Parameter(Mandatory=$true, HelpMessage="Local drive location or UNC path, ex. - c:\folder\folder\")]
    $completePath
)

#Set Error Action to Stop
$ErrorActionPreference = "Stop"
$appSourceName = $($MyInvocation.MyCommand.Name)

# This checks to be sure the Application Event Log Source Name already exists.
# If it does not exist then create the Source Name in the App Log.
# Wrap check i try/false to catch SourceExists() throwing access denied on failure
$SourceExists = try {
    [System.Diagnostics.EventLog]::SourceExists($appSourceName)
} catch {
    $false
}

if(-not $SourceExists)
{
    # Create the Source definition
    New-EventLog -Source $appSourceName -LogName Application
}

Write-EventLog -LogName Application -Source $appSourceName -EntryType Information -EventId 7777 -Message $('Beginning run of script: {0}' -f $appSourceName)

# Import the logging module. If it fails to import, stop the script.
try {
    #Dot Source required Function Libraries
    Import-Module .\Logging_Functions.psm1 -AsCustomObject -Force -DisableNameChecking -ErrorAction Stop    
}
catch {
    Write-EventLog -LogName Application -Source $appSourceName -EntryType Error -EventId 7778 -Message 'Unable to import module for script logging'
    throw
}


#endregion

#----------------------------------------------------------[Declarations]----------------------------------------------------------

#Script Version
$sScriptVersion = "1.1"

#Log File Info
$sLogPath = ".\logs"

#Check if the logs folder exists and if not, create it
if (!(Test-Path $sLogPath))
{
    New-Item -ItemType Directory -Force -Path $sLogPath
}

# Variables for the log file
$sLogName = "$($MyInvocation.MyCommand.Name)-Log-{0}.log" -f [DateTime]::Now.ToString("yyyy-mm-dd_hh-mm-ss")
$sLogFile = $sLogPath + "\" + $sLogName


<#
# Variables for all the source and destination paths
$sourcePath = 'c:\powershell\source\*'
$moveToPath = 'c:\powershell\process\'
$processPath = 'C:\powershell\process\*'
$completePath = 'c:\powershell\complete\'
#>

# File name for output of data
# $sFileName = ".\[File Name]-{0}.csv" -f [DateTime]::Now.ToString("yyyy-mm-dd_hh-mm-ss")

#-----------------------------------------------------------[Functions]------------------------------------------------------------



#-----------------------------------------------------------[Execution]------------------------------------------------------------

# Create Log File
Log-Start -LogPath $sLogPath -LogName $sLogName -ScriptVersion $sScriptVersion

# Create the stopwatch and start the count
$stopWatch = New-Object System.Diagnostics.Stopwatch
$stopWatch.Start()

# Create variable for the source files to be moved
try {
    $sourcefiles = Get-ChildItem -Path $sourcePath -Filter *.zip -ErrorAction Stop
    Write-EventLog -LogName Application -Source $appSourceName -EntryType Information -EventId 7777 -Message $('Getting list of files to move to the process folder from path {0}.' -f $sourcePath)
}
catch {
    Write-EventLog -LogName Application -Source $appSourceName -EntryType Error -EventId 7778 -Message $('Could not get file list from path: {0}.' -f $sourcePath)
    throw
}

# Move each file from the source folder to the process folder
foreach ($file in $sourceFiles) {
    try {        
        Move-Item -Path $file.PSPath -Destination $moveToPath -ErrorAction Stop
        Write-EventLog -LogName Application -Source $appSourceName -EntryType Information -EventId 7777 -Message $('File {0} has been moved to the process folder.' -f $file.PSChildName)
        Log-Write -LogPath $sLogFile -LineValue $('File {0} has been moved to the process folder.' -f $file.PSChildName)
    }
    catch {
        Write-EventLog -LogName Application -Source $appSourceName -EntryType Error -EventId 7778 -Message $('File {0} failed to be moved to the process folder.' -f $file.PSChildName)
    }    
}

# Run the Defender Scan the process folder and exit script if this fails
try {
    Log-Write -LogPath $sLogFile -LineValue 'Defender Scan started...'
    Start-MpScan -ScanPath $moveToPath -ScanType CustomScan -ErrorAction Stop
    Log-Write -LogPath $sLogFile -LineValue 'Defender Scan complete.'
    Write-EventLog -LogName Application -Source $appSourceName -EntryType Information -EventId 7777 -Message 'Defender Scan completed successfully.'
}
catch {
    $errMsg = $_
    Write-EventLog -LogName Application -Source $appSourceName -EntryType Error -EventId 7778 -Message $('Start-MpScan failed to execute correctly. Error: {0}' -f $errMsg)
    throw                
}

# Remove any threats with Defender that were detected in the process folder
# Exit the script if this fails
try {
    Log-Write -LogPath $sLogFile -LineValue 'Defender removing any threats detected...'
    Remove-MpThreat -ErrorAction Stop
    Log-Write -LogPath $sLogFile -LineValue 'Defender threat removal complete.'
    Write-EventLog -LogName Application -Source $appSourceName -EntryType Information -EventId 7777 -Message 'Defender Threat removal completed successfully.'    
}
catch {
    Write-EventLog -LogName Application -Source $appSourceName -EntryType Error -EventId 7778 -Message 'Remove-MpThreat failed to execute correctly.'
    throw      
}

# Create variable for the processed files to be moved
# Exit the script if this fails
try {
    $processZipFiles = Get-ChildItem -Path $processPath -Filter *.zip
    Write-EventLog -LogName Application -Source $appSourceName -EntryType Information -EventId 7777 -Message $('Getting list of files to move to the completed folder from path {0}.' -f $processPath)
}
catch {
    Write-EventLog -LogName Application -Source $appSourceName -EntryType Error -EventId 7778 -Message $('Could not get file list from path: {0}.' -f $processPath)
    throw
}

# Move processed files to the completed folder
# Exit the script of the move command fails
foreach ($file in $processZipFiles) { 
    try {
        Move-Item -Path $file.PSPath -Destination $completePath
        Write-EventLog -LogName Application -Source $appSourceName -EntryType Information -EventId 7777 -Message $('File {0} has been moved to the completed folder.' -f $file.PSChildName)
        Log-Write -LogPath $sLogFile -LineValue $('File {0} has been moved to the complete folder.' -f $file.PSChildName)     
    }
    catch {
        Write-EventLog -LogName Application -Source $appSourceName -EntryType Error -EventId 7778 -Message $('File {0} failed to be moved to the completed folder.' -f $file.PSChildName)
        throw
    }       
}

# Stop the stopwatch and place in variable
$stopWatch.Stop()
$ts = $stopWatch.Elapsed

# Add the elapsed time to the log
Log-Write -LogPath $sLogFile -LineValue ' '
Log-Write -LogPath $sLogFile -LineValue $("Script Completed in {0} minutes, {1} seconds, {2} milliseconds" -f $ts.Minutes, $ts.Seconds, $ts.Milliseconds )

# Finish log and close out file
Log-Finish -LogPath $sLogFile

# Debugging
# Remove Items from scanned folder and then copy items for further testing
# Remove-Item -Path 'c:\powershell\complete\*.*'
# Copy-Item -Path 'C:\powershell\source\backups' -Filter *.zip -Destination 'C:\powershell\source'