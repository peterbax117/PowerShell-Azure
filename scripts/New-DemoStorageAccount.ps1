<#
.SYNOPSIS
    Creates an Azure Storage Account, assigns required RBAC for the signed-in principal, and uploads sample blob data.

.DESCRIPTION
    End-to-end demo script that:
      1. Ensures an Azure context (connects only if not already signed in).
      2. Creates a Resource Group (idempotent).
      3. Creates a Storage Account with secure defaults (TLS 1.2, HTTPS only, public blob access disabled).
      4. Assigns 'Storage Blob Data Contributor' to the signed-in principal at the storage account scope.
      5. Creates a private container using AAD-based data plane access.
      6. Generates sample files locally and uploads them to the container.
      7. Returns a summary object describing the created resources.

    Supports -WhatIf and -Confirm for all mutating operations.

.PARAMETER SubscriptionId
    Optional Azure Subscription ID. Defaults to the current Az context after sign-in.

.PARAMETER ResourceGroupName
    Resource group to create or reuse.

.PARAMETER Location
    Azure region for the resource group and storage account.

.PARAMETER StorageAccountName
    Optional storage account name (3-24 lowercase alphanumeric). If omitted, a name is generated.

.PARAMETER ContainerName
    Blob container to create within the storage account.

.PARAMETER FileCount
    Number of sample files to generate and upload.

.PARAMETER FileSizeKB
    Approximate size in KB for each generated sample file.

.EXAMPLE
    .\New-DemoStorageAccount.ps1

.EXAMPLE
    .\New-DemoStorageAccount.ps1 -ResourceGroupName "rg-demo" -Location "eastus2" -FileCount 25 -Verbose

.EXAMPLE
    .\New-DemoStorageAccount.ps1 -WhatIf

.OUTPUTS
    [pscustomobject] with ResourceGroup, Location, StorageAccount, Container, FilesUploaded.

.NOTES
    Requires the Az PowerShell module (Az.Accounts, Az.Resources, Az.Storage).
    The signed-in principal must have rights to create role assignments at the chosen scope.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName = "rg-storage-demo",

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Location = "centralus",

    [Parameter()]
    [ValidateLength(3, 24)]
    [ValidatePattern('^[a-z0-9]+$')]
    [string]$StorageAccountName,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ContainerName = "sample-data",

    [Parameter()]
    [ValidateRange(1, 10000)]
    [int]$FileCount = 10,

    [Parameter()]
    [ValidateRange(1, 102400)]
    [int]$FileSizeKB = 4
)

$ErrorActionPreference = 'Stop'

function New-RandomStorageAccountName {
    param([string]$Prefix = "st", [int]$Length = 18)
    $chars = "abcdefghijklmnopqrstuvwxyz0123456789"
    $remaining = $Length - $Prefix.Length
    $rand = -join ((1..$remaining) | ForEach-Object { $chars[(Get-Random -Min 0 -Max $chars.Length)] })
    return ($Prefix + $rand)
}

function Get-CurrentPrincipalObjectId {
    # Returns the ObjectId (principalId) of the signed-in identity.
    # Works for interactive user, service principal, and most automation contexts.

    try {
        $u = Get-AzADUser -SignedIn -ErrorAction Stop
        if ($u -and $u.Id) { return $u.Id }
    } catch { }

    try {
        $ctx = Get-AzContext
        if ($ctx -and $ctx.Account -and $ctx.Account.Id) {
            $acct = $ctx.Account.Id
            if ($acct -match '^[0-9a-fA-F-]{36}$') {
                $sp = Get-AzADServicePrincipal -ApplicationId $acct -ErrorAction Stop
                if ($sp -and $sp.Id) { return $sp.Id }
            }
            $u2 = Get-AzADUser -UserPrincipalName $acct -ErrorAction SilentlyContinue
            if ($u2 -and $u2.Id) { return $u2.Id }
        }
    } catch { }

    throw "Unable to resolve signed-in principal ObjectId. Ensure you are signed in (Connect-AzAccount) with Graph permissions to query Entra ID."
}

function Add-RoleAssignmentIfMissing {
    param(
        [Parameter(Mandatory = $true)][string]$ObjectId,
        [Parameter(Mandatory = $true)][string]$Scope,
        [Parameter(Mandatory = $true)][string]$RoleDefinitionName
    )

    $existing = Get-AzRoleAssignment -ObjectId $ObjectId -Scope $Scope -ErrorAction SilentlyContinue |
                Where-Object { $_.RoleDefinitionName -eq $RoleDefinitionName }

    if ($existing) {
        Write-Verbose "RBAC: '$RoleDefinitionName' already assigned at scope $Scope."
        return
    }

    if ($PSCmdlet.ShouldProcess($Scope, "Assign role '$RoleDefinitionName' to $ObjectId")) {
        Write-Verbose "RBAC: Assigning '$RoleDefinitionName' to ObjectId $ObjectId at scope $Scope."
        New-AzRoleAssignment -ObjectId $ObjectId -RoleDefinitionName $RoleDefinitionName -Scope $Scope | Out-Null
    }
}

# ------------------------
# Login / Subscription
# ------------------------
if (-not (Get-AzContext)) {
    Write-Verbose "No Az context found. Connecting to Azure..."
    Connect-AzAccount | Out-Null
}

if (-not $SubscriptionId) {
    $SubscriptionId = (Get-AzContext).Subscription.Id
}

if (-not $SubscriptionId) {
    throw "Could not resolve a SubscriptionId. Provide -SubscriptionId or sign in with Connect-AzAccount."
}

Write-Verbose "Setting context to subscription $SubscriptionId."
Select-AzSubscription -SubscriptionId $SubscriptionId | Out-Null

# ------------------------
# Resource Group
# ------------------------
$rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $rg) {
    if ($PSCmdlet.ShouldProcess($ResourceGroupName, "Create resource group in $Location")) {
        Write-Verbose "Creating resource group '$ResourceGroupName' in '$Location'."
        New-AzResourceGroup -Name $ResourceGroupName -Location $Location | Out-Null
    }
} else {
    Write-Verbose "Resource group '$ResourceGroupName' already exists."
}

# ------------------------
# Storage Account
# ------------------------
if (-not $StorageAccountName) {
    $StorageAccountName = New-RandomStorageAccountName
    Write-Verbose "No StorageAccountName provided. Generated: $StorageAccountName"
}

$storageParams = @{
    ResourceGroupName      = $ResourceGroupName
    Name                   = $StorageAccountName
    Location               = $Location
    SkuName                = 'Standard_LRS'
    Kind                   = 'StorageV2'
    AccessTier             = 'Hot'
    AllowBlobPublicAccess  = $false
    EnableHttpsTrafficOnly = $true
    MinimumTlsVersion      = 'TLS1_2'
}

if (-not $PSCmdlet.ShouldProcess($StorageAccountName, "Create storage account in $ResourceGroupName")) {
    Write-Verbose "Skipping storage account creation due to -WhatIf."
    return
}

Write-Verbose "Creating storage account '$StorageAccountName'."
$storage = New-AzStorageAccount @storageParams

# ------------------------
# RBAC permission for uploads (data plane)
# ------------------------
$principalObjectId = Get-CurrentPrincipalObjectId
$storageScope = $storage.Id

Add-RoleAssignmentIfMissing -ObjectId $principalObjectId -Scope $storageScope -RoleDefinitionName "Storage Blob Data Contributor"

# ------------------------
# Use Azure AD auth for data plane operations
# ------------------------
Write-Verbose "Creating storage context using connected account (Azure AD)."
$ctx = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount

# RBAC propagation: retry container op with exponential backoff capped at 30s.
$maxAttempts = 8
$container = $null

for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    try {
        Write-Verbose "Ensuring container '$ContainerName' exists (attempt $attempt/$maxAttempts)."
        $container = New-AzStorageContainer -Name $ContainerName -Context $ctx -Permission Off
        break
    } catch {
        if ($attempt -eq $maxAttempts) { throw }
        $wait = [Math]::Min(30, [Math]::Pow(2, $attempt))
        Write-Verbose "RBAC may still be propagating. Waiting $wait seconds..."
        Start-Sleep -Seconds $wait
    }
}

# ------------------------
# Generate Sample Files
# ------------------------
$tempFolder = Join-Path -Path $env:TEMP -ChildPath ("SampleBlobs_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
New-Item -ItemType Directory -Path $tempFolder | Out-Null

try {
    Write-Verbose "Generating $FileCount sample files (~$FileSizeKB KB each) in $tempFolder."

    for ($i = 1; $i -le $FileCount; $i++) {
        $fileName = "samplefile_$('{0:D3}' -f $i).txt"
        $filePath = Join-Path $tempFolder $fileName

        $bytes = New-Object byte[] ($FileSizeKB * 1024)
        (New-Object System.Random).NextBytes($bytes)
        [System.IO.File]::WriteAllBytes($filePath, $bytes)
    }

    # ------------------------
    # Upload to Blob (data plane using Azure AD)
    # ------------------------
    Write-Verbose "Uploading sample files to container '$ContainerName'."

    $files = Get-ChildItem -Path $tempFolder -File

    if ($PSVersionTable.PSVersion.Major -ge 7 -and $files.Count -ge 4) {
        # Parallel upload for PS 7+
        $files | ForEach-Object -ThrottleLimit 8 -Parallel {
            $f = $_
            Set-AzStorageBlobContent -File $f.FullName -Container $using:ContainerName -Blob $f.Name -Context $using:ctx -Force | Out-Null
        }
    } else {
        foreach ($file in $files) {
            $uploaded = $false
            for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
                try {
                    Set-AzStorageBlobContent -File $file.FullName -Container $ContainerName -Blob $file.Name -Context $ctx -Force | Out-Null
                    $uploaded = $true
                    break
                } catch {
                    if ($attempt -eq $maxAttempts) { throw }
                    $wait = [Math]::Min(30, [Math]::Pow(2, $attempt))
                    Write-Verbose "Upload permission may still be propagating. Retrying in $wait seconds..."
                    Start-Sleep -Seconds $wait
                }
            }
            if (-not $uploaded) {
                throw "Failed to upload $($file.Name) after retries."
            }
        }
    }
}
finally {
    Write-Verbose "Cleaning up local temp folder."
    Remove-Item -Recurse -Force $tempFolder -ErrorAction SilentlyContinue
}

# ------------------------
# Output summary object
# ------------------------
[pscustomobject]@{
    ResourceGroup  = $ResourceGroupName
    Location       = $Location
    StorageAccount = $StorageAccountName
    Container      = $ContainerName
    FilesUploaded  = $FileCount
}
