<#
.SYNOPSIS
    Reports on Azure Key Vaults across all accessible subscriptions and their secret inventory.

.DESCRIPTION
    Iterates through every Azure subscription the signed-in account has access to,
    enumerates all Key Vaults in each subscription's Resource Groups, and for each
    Key Vault that contains at least one secret reports the vault name, resource group,
    subscription, total secret count, and the date of the soonest-expiring secret.

    Results are written to the console and optionally exported to a timestamped CSV.

    Requires an active Az context — run Connect-AzAccount before executing.
    The account must have at minimum Key Vault Reader + Key Vault Secrets User (or
    equivalent) on each vault to list secrets.  Vaults where access is denied are
    skipped with a warning rather than terminating the script.

.INPUTS
    None. Subscription and Key Vault lists are discovered automatically.

.OUTPUTS
    A CSV file named Report-KeyVault-Secret-<yyyy-MM-dd_HH-mm-ss>.csv written to
    the current directory if any secrets are found.

.NOTES
    Version:        1.1
    Author:         Pete Baxter
    Creation Date:  2024-01-01
    Purpose/Change: Added ResourceGroup, SecretCount, NextExpiry to output;
                    replaced array concatenation with List for performance;
                    added per-vault error handling for access-denied scenarios.

.EXAMPLE
    # Sign in first, then run
    Connect-AzAccount
    .\Report-KeyVault-Azure.ps1

.EXAMPLE
    # Run against a specific subscription only
    Connect-AzAccount
    Set-AzContext -SubscriptionId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
    .\Report-KeyVault-Azure.ps1
#>

# Connect to the Azure Tenant and provide your credentials
# This is the first step to interact with Azure resources
#Connect-AzAccount

# Define the file name for the output data
# The file name includes the current date and time to avoid overwriting previous reports
$sFileName = ".\Report-KeyVault-Secret-{0}.csv" -f [DateTime]::Now.ToString("yyyy-mm-dd_hh-mm-ss")

# Create an array to store the output data
# This array will be filled with custom objects representing each secret found in the Key Vaults
$output = [System.Collections.Generic.List[PSCustomObject]]::new()

# Retrieve a list of all Azure Subscriptions the user has access to
# Each subscription will be processed to find Key Vaults and their secrets
$subScription = Get-AzSubscription

# Loop through each subscription
foreach($sub in $subScription)
{
    # Set the current Azure context to the subscription being processed
    # This allows the script to access resources within this subscription
    Set-AzContext -SubscriptionId $sub.SubscriptionId
    
    # Retrieve the names of all Resource Groups within the current subscription
    # Each Resource Group will be processed to find Key Vaults
    $resourceGroupName = (Get-AzResourceGroup).ResourceGroupName
    
    # Loop through each Resource Group
    foreach($rg in $resourceGroupName)
    {
        # Retrieve all Key Vaults within the current Resource Group
        # Each Key Vault will be processed to find its secrets
        $keyVaults = Get-AzKeyVault -ResourceGroupName $rg
        
        # Loop through each Key Vault
        foreach($kv in $keyVaults)
        {
            $keyVaultName = $kv.VaultName

            # Retrieve all secrets; catch access-denied or firewall blocks gracefully
            $allSecrets = try {
                Get-AzKeyVaultSecret -VaultName $keyVaultName -ErrorAction Stop
            } catch {
                Write-Warning "Could not access Key Vault '$keyVaultName': $($_.Exception.Message)"
                $null
            }

            if ($allSecrets)
            {
                # Find the soonest-expiring secret (if any have an expiry set)
                $nextExpiry = $allSecrets |
                              Where-Object { $_.Expires } |
                              Sort-Object Expires |
                              Select-Object -First 1 -ExpandProperty Expires

                $result = [PSCustomObject] @{
                    Subscription  = $sub.Name
                    ResourceGroup = $rg
                    KeyVault      = $kv.VaultName
                    SecretCount   = $allSecrets.Count
                    NextExpiry    = $nextExpiry
                }

                $output.Add($result)
            }
        }
    }
}

# If any secrets were found, export the output data to a CSV file
# The file path is defined at the beginning of the script
if( $output ) { 
    $output | Export-Csv -Path $sFileName -NoTypeInformation
}