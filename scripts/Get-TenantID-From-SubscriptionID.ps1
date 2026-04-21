<#
.SYNOPSIS
    Returns the Azure AD Tenant ID associated with a given Subscription ID.

.DESCRIPTION
    Sends an unauthenticated GET request to the Azure management endpoint for the
    subscription. Azure responds with HTTP 401 and a WWW-Authenticate header that
    contains the tenant's login URL. The Tenant ID (a GUID) is extracted from that
    header using a regex match — no credentials or Az module required.

    Accepts one or more Subscription IDs via parameter or pipeline and emits a
    [pscustomobject] per subscription with SubscriptionId and TenantId properties.

.PARAMETER SubscriptionId
    One or more Azure Subscription IDs (GUID format). Accepts pipeline input.

.EXAMPLE
    .\Get-TenantID-From-SubscriptionID.ps1 -SubscriptionId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'

.EXAMPLE
    'sub1-guid','sub2-guid' | .\Get-TenantID-From-SubscriptionID.ps1

.NOTES
    Version:    2.1
    Author:     Pete Baxter (pete.baxter@microsoft.com)
    Updated:    2026-04-20 — pipeline + array support; cross-edition header parsing
                             (PS 5.1 / 7.x); robust authorization_uri regex;
                             pipeline-friendly object output.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
                     ErrorMessage = 'SubscriptionId must be a valid GUID (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx).')]
    [string[]]$SubscriptionId
)

begin {
    $ErrorActionPreference = 'Stop'
}

process {
    foreach ($id in $SubscriptionId) {
        $uri = "https://management.azure.com/subscriptions/$id`?api-version=2022-12-01"

        # The unauthenticated call returns 401; capture the response object from either path
        $response = try {
            (Invoke-WebRequest -UseBasicParsing -Uri $uri).BaseResponse
        } catch {
            $_.Exception.Response
        }

        if (-not $response) {
            throw "No HTTP response received for subscription '$id'. Verify the Subscription ID is correct and that management.azure.com is reachable."
        }

        # Read WWW-Authenticate header in a way that works on both PS 5.1 and 7.x
        $authHeader = $null
        try {
            if ($response.Headers -is [System.Collections.IDictionary]) {
                $authHeader = $response.Headers['WWW-Authenticate']
            } elseif ($response.Headers.GetValues) {
                $authHeader = ($response.Headers.GetValues('WWW-Authenticate')) -join ' '
            }
        } catch {
            $authHeader = $null
        }

        if (-not $authHeader) {
            # Last-resort fallback: stringify the header collection
            $authHeader = $response.Headers.ToString()
        }

        # Header looks like: Bearer authorization_uri="https://login.windows.net/<tenantId>", ...
        if ($authHeader -match 'authorization_uri="https?://[^/]+/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})"') {
            $tenantId = $Matches[1]
            Write-Verbose "Tenant ID for subscription '$id': $tenantId"
            [pscustomobject]@{
                SubscriptionId = $id
                TenantId       = $tenantId
            }
        } else {
            throw "Could not extract a Tenant ID from the WWW-Authenticate header for '$id'.`nHeader text received:`n$authHeader"
        }
    }
}
