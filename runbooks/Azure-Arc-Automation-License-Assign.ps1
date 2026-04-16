<#
.SYNOPSIS
Assigns or clears Azure Arc ESU license profiles for Arc-enabled servers based on OS eligibility.

.DESCRIPTION
This runbook authenticates using the Automation Account system-assigned managed identity and processes
Arc machines in a target resource group.

Behavior:
- Connected machines with osSku matching "Windows Server 2012*" and no ESU assignment:
    assigns a random available Windows Server 2012 Arc license and sets software assurance true.
- Connected machines not matching Windows Server 2012:
    clears ESU profile and sets software assurance true.
- Disconnected machines are ignored.

The script is safe to rerun (idempotent for already-compliant machines).

.PREREQUISITES
- Azure Automation Account with System Assigned Managed Identity enabled.
- Runbook environment exposes IDENTITY_ENDPOINT and IDENTITY_HEADER.
- Access to Azure Resource Manager endpoint: https://management.azure.com/

.REQUIRED PERMISSIONS
Managed identity must have rights to:
- Read: Microsoft.HybridCompute/licenses and Microsoft.HybridCompute/machines
- Write: Microsoft.HybridCompute/machines/licenseProfiles

.PARAMETER ArcLicenseRG
Resource group containing Arc license resources.

.PARAMETER ArcMachinesRg
Resource group containing Arc-enabled machine resources.

.PARAMETER SubscriptionId
Azure subscription ID containing the target Arc resources (GUID format).

.PARAMETER ApiVersion
ARM API version used for Microsoft.HybridCompute REST requests.

.THROTTLING AND RETRIES
REST calls use retry logic:
- Retries up to MaxRetries (default: 3)
- Handles HTTP 429 using Retry-After header when present
- Uses exponential backoff for other transient failures

.OUTPUTS
Emits progress and a final summary:
- Processed machine count
- Assigned ESU count
- Cleared ESU count

.NOTES
- ESU license selection is random among available eligible licenses to spread assignments.
- API version should be validated periodically against Microsoft.HybridCompute.

.EXAMPLE
.\Azure-Arc-Automation-License-Assign.ps1

.EXAMPLE
.\Azure-Arc-Automation-License-Assign.ps1 -ArcLicenseRG "ArcLicenses-RG" -ArcMachinesRg "ArcServers-RG" -SubscriptionId "00000000-0000-0000-0000-000000000000"

.EXAMPLE
.\Azure-Arc-Automation-License-Assign.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$ArcLicenseRG = "ArcResources",

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$ArcMachinesRg = "ArcResources",

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string]$SubscriptionId = "8b1688ea-ffb3-4723-9058-9bddd7b92a33",

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$ApiVersion = "2025-01-13"
)

#Authenticate to Azure using RestAPI and System Assigned Managed Identity as documented https://urldefense.com/v3/__https://learn.mi__;!!P9vvK-4S!hCiXeD4Gkrxt5zEf7E47AgV4gshUdVLjaELfTVS3WGMifWuCjwZEsGYijaetHOfLZCOZABseEs6lGUmzgFsGcfoDlBQolg$/azure/automation/enable-managed-identity-for-automation#get-access-token-for-system-assigned-managed-identity-using-http-get
if ([string]::IsNullOrWhiteSpace($env:IDENTITY_ENDPOINT) -or [string]::IsNullOrWhiteSpace($env:IDENTITY_HEADER)) {
    throw "Managed identity environment variables are missing. Ensure this runbook runs in Azure Automation with System Assigned Managed Identity enabled."
}

$resource = "?resource=https://management.azure.com/"
$url = $env:IDENTITY_ENDPOINT + $resource
$identityHeaders = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$identityHeaders.Add("X-IDENTITY-HEADER", $env:IDENTITY_HEADER)
$identityHeaders.Add("Metadata", "True")
$accessToken = Invoke-RestMethod -Uri $url -Method 'GET' -Headers $identityHeaders
if ([string]::IsNullOrWhiteSpace($accessToken.access_token)) {
    throw "Failed to acquire a managed identity access token for Azure Resource Manager."
}

#Helper function for REST calls with retry and 429 backoff
function Invoke-RestMethodWithRetry {
    param(
        [string]$Method,
        [string]$Uri,
        [hashtable]$Headers,
        [string]$Body,
        [int]$MaxRetries = 3
    )
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            $params = @{
                Method      = $Method
                Uri         = $Uri
                Headers     = $Headers
                ErrorAction = 'Stop'
            }
            if ($Body) { $params['Body'] = $Body }
            return (Invoke-RestMethod @params)
        } catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            if ($statusCode -eq 429 -and $attempt -lt $MaxRetries) {
                $retryAfter = $_.Exception.Response.Headers['Retry-After']
                $waitSeconds = if ($retryAfter) { [int]$retryAfter + 1 } else { [math]::Pow(2, $attempt) }
                Write-Warning "Throttled (429). Retrying in $waitSeconds seconds... (attempt $attempt/$MaxRetries)"
                Start-Sleep -Seconds $waitSeconds
            } elseif ($attempt -lt $MaxRetries) {
                Write-Warning "Request failed (HTTP $statusCode): $($_.Exception.Message). Retrying... (attempt $attempt/$MaxRetries)"
                Start-Sleep -Seconds ([math]::Pow(2, $attempt))
            } else {
                throw
            }
        }
    }
}

#Build common header
$headers = @{
    "Authorization" = "Bearer $($accessToken.access_token)"
    "Content-Type" = "application/json"
}

#Query RestAPI to get the Arc Licenses in the Resource Group
Write-Output "Loading Arc Licenses"
$uri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ArcLicenseRG/providers/Microsoft.HybridCompute/licenses?api-version=$ApiVersion"
$ArcLicenses = Invoke-RestMethodWithRetry -Method Get -Uri $uri -Headers $headers
$WindowsServer2012R2ArcLicenses = $ArcLicenses.value | Where-Object {$_.properties.licenseDetails.target -eq "Windows Server 2012"}

#Query RestAPI to get the Arc Machines in the Resource Group
Write-Output "Loading Arc Machines"
$uri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ArcMachinesRg/providers/Microsoft.HybridCompute/machines?api-version=$ApiVersion"

if (-not $WindowsServer2012R2ArcLicenses -or $WindowsServer2012R2ArcLicenses.Count -eq 0) {
    throw "No Arc licenses were found for Windows Server 2012. Cannot assign ESU licenses."
}

$machineCount = 0
$assignedCount = 0
$clearedCount = 0

do {
    $response = Invoke-RestMethodWithRetry -Method Get -Uri $uri -Headers $headers

    foreach ($machine in $response.value) {
        $machineCount++
        $machineName = $machine.name
        $machineLocation = $machine.location
        $machineStatus = $machine.properties.status
        $machineOsSku = $machine.properties.osSku
        $licenseAssignmentState = $machine.properties.licenseProfile.esuProfile.licenseAssignmentState
        $softwareAssurance = $machine.properties.licenseProfile.softwareAssurance.softwareAssuranceCustomer

        $licenseProfileUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ArcMachinesRg/providers/Microsoft.HybridCompute/machines/$machineName/licenseProfiles/default?api-version=$ApiVersion"

        #Windows 2012 - assign an ESU license if not already assigned to a connected (online) machine
        if (($machineOsSku -like "Windows Server 2012*") -and ($machineStatus -eq "Connected") -and ($licenseAssignmentState -ne 'Assigned'))
        {
            $ArcLicenseID = ($WindowsServer2012R2ArcLicenses | Get-Random).id  #Randomly pick an appropriate license for roughly even distribution

            $body = @{
                location = $machineLocation
                properties = @{
                    esuProfile = @{
                        assignedLicense = $ArcLicenseID
                    };
                    softwareAssurance = @{
                        softwareAssuranceCustomer = $true;
                    };
                }
            } | ConvertTo-Json -Depth 10
            try {
                $assignAction = "Assign ESU license $ArcLicenseID and set software assurance"
                if ($PSCmdlet.ShouldProcess($machineName, $assignAction)) {
                    Invoke-RestMethodWithRetry -Method Put -Uri $licenseProfileUri -Headers $headers -Body $body | Out-Null
                    $assignedCount++
                    Write-Output "$machineName is running $machineOsSku and is not currently assigned an ESU license. Assigned license $ArcLicenseID"
                }
            } catch {
                Write-Warning "Failed to assign license for $machineName : $_"
            }
        }
        #Else make sure software assurance is assigned for non-ESU eligible connected machines - clear ESU license properties
        elseif (($machineStatus -eq "Connected") -and ($machineOsSku -notlike "Windows Server 2012*") -and ($licenseAssignmentState -eq 'Assigned' -or $softwareAssurance -eq $false))
        {
            $body = @{
                location = $machineLocation
                properties = @{
                    esuProfile = @{};
                    softwareAssurance = @{
                        softwareAssuranceCustomer = $true;
                    };
                }
            } | ConvertTo-Json -Depth 10
            try {
                $clearAction = "Clear ESU properties and set software assurance"
                if ($PSCmdlet.ShouldProcess($machineName, $clearAction)) {
                    Invoke-RestMethodWithRetry -Method Put -Uri $licenseProfileUri -Headers $headers -Body $body | Out-Null
                    $clearedCount++
                    Write-Output "$machineName is running $machineOsSku and is not eligible for Windows ESUs. Clearing ESU properties. Setting software assurance."
                }
            } catch {
                Write-Warning "Failed to update license profile for $machineName : $($machine.name)"
            }
        }

        if (($machineCount % 1000) -eq 0) {
            Write-Output "Processed $machineCount machines so far... Assigned: $assignedCount, Cleared: $clearedCount"
        }
    }
    
    $uri = $response.nextLink
} while ($uri)

Write-Output "Completed processing $machineCount machines. Assigned: $assignedCount, Cleared: $clearedCount"
