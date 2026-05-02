<#
.SYNOPSIS
    Reports Azure resource usage and costs for a subscription via the Consumption REST API.

.DESCRIPTION
    Queries the Azure Consumption / Usage Details API for the specified subscription
    and date range, handling all response pagination automatically via nextLink.

    For each usage row returned the script captures: date, resource group, resource
    name, Azure region, meter category/sub-category/name, quantity, unit of measure,
    unit price, cost, and billing currency.

    Output is presented as:
      1. A grouped summary table of total cost by Meter Category.
      2. A full per-row detail table.
      3. Optionally an exported CSV file (via -OutputCsv).

    Requires an active Az context — run Connect-AzAccount before executing.

.PARAMETER SubscriptionId
    Azure Subscription ID to query. Defaults to the subscription in the current
    Az context (Get-AzContext).

.PARAMETER StartDate
    Inclusive start date for the usage query in yyyy-MM-dd format.
    Defaults to the first day of the current calendar month.

.PARAMETER EndDate
    Inclusive end date for the usage query in yyyy-MM-dd format.
    Defaults to today.

.PARAMETER OutputCsv
    Optional path for a CSV export of the full result set.
    Example: .\costs-march-2024.csv

.INPUTS
    None. All inputs are via parameters or the current Az context.

.OUTPUTS
    Formatted tables to the console. Optional CSV via -OutputCsv.

.NOTES
    Version:        1.0
    Author:         Pete Baxter
    Creation Date:  2024-01-01
    Purpose/Change: Initial release — replaced incomplete CPU-usage prototype with
                    a fully paginated billing cost report.
    API Version:    Microsoft.Consumption/usageDetails 2021-10-01

.EXAMPLE
    # Report costs for the current month in the active subscription
    .\Get-Costs.ps1

.EXAMPLE
    # Report costs for March 2024 and save to CSV
    .\Get-Costs.ps1 -StartDate 2024-03-01 -EndDate 2024-03-31 -OutputCsv .\march-2024-costs.csv

.EXAMPLE
    # Report costs for a specific subscription
    .\Get-Costs.ps1 -SubscriptionId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' -StartDate 2024-01-01 -EndDate 2024-01-31
#>

param(
    # Subscription to query — defaults to the currently active Az context
    [string]$SubscriptionId = (Get-AzContext).Subscription.Id,

    # Inclusive start date (yyyy-MM-dd). Defaults to the first day of the current month.
    [string]$StartDate = (Get-Date -Day 1).ToString('yyyy-MM-dd'),

    # Inclusive end date (yyyy-MM-dd). Defaults to today.
    [string]$EndDate = (Get-Date).ToString('yyyy-MM-dd'),

    # Optional path to export results as a CSV file. Leave blank to display only.
    [string]$OutputCsv = ''
)

$ErrorActionPreference = 'Stop'

# Verify we have an active context before proceeding
if (-not (Get-AzContext)) {
    throw "No active Azure context found. Run Connect-AzAccount first."
}

Write-Host "Fetching costs for subscription '$SubscriptionId' from $StartDate to $EndDate..." -ForegroundColor Cyan

$token  = (Get-AzAccessToken).Token
$headers = @{
    'Authorization' = "Bearer $token"
    'Content-Type'  = 'application/json'
}

# Build the initial request URI — the API returns paged results via nextLink
$uri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Consumption/usageDetails?" +
       "`$filter=properties/usageStart ge '$StartDate' and properties/usageEnd le '$EndDate'&" +
       "api-version=2021-10-01"

$allRows  = [System.Collections.Generic.List[PSCustomObject]]::new()
$pageNum  = 0

do {
    $pageNum++
    Write-Host "  Retrieving page $pageNum..." -ForegroundColor Gray

    $result = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers

    foreach ($row in $result.value) {
        $allRows.Add([PSCustomObject]@{
            Date          = $row.properties.date
            SubscriptionId = $row.properties.subscriptionId
            ResourceGroup  = $row.properties.resourceGroupName
            ResourceName   = $row.properties.resourceName
            Location       = $row.properties.resourceLocation
            MeterCategory  = $row.properties.meterDetails.meterCategory
            MeterSubCategory = $row.properties.meterDetails.meterSubCategory
            MeterName      = $row.properties.meterDetails.meterName
            Quantity       = $row.properties.quantity
            UnitOfMeasure  = $row.properties.meterDetails.unitOfMeasure
            UnitPrice      = $row.properties.unitPrice
            Cost           = [math]::Round($row.properties.cost, 4)
            Currency       = $row.properties.billingCurrency
            Tags           = ($row.properties.additionalInfo)
        })
    }

    $uri = $result.nextLink  # null/empty when no more pages

} while ($uri)

Write-Host "Total usage rows retrieved: $($allRows.Count)" -ForegroundColor Green
Write-Host ""

if ($allRows.Count -gt 0) {
    # Show a summary grouped by MeterCategory
    Write-Host "--- Cost Summary by Meter Category ---" -ForegroundColor Cyan
    $allRows |
        Group-Object MeterCategory |
        Select-Object Name, @{N='TotalCost'; E={ [math]::Round(($_.Group | Measure-Object Cost -Sum).Sum, 2) }} |
        Sort-Object TotalCost -Descending |
        Format-Table -AutoSize

    # Full detail table
    Write-Host "--- Detailed Usage ---" -ForegroundColor Cyan
    $allRows | Format-Table Date, ResourceGroup, ResourceName, MeterCategory, Quantity, Cost, Currency -AutoSize

    if ($OutputCsv) {
        $allRows | Export-Csv -Path $OutputCsv -NoTypeInformation
        Write-Host "Results exported to: $OutputCsv" -ForegroundColor Green
    }
} else {
    Write-Host "No usage data found for the specified period." -ForegroundColor Yellow
}
