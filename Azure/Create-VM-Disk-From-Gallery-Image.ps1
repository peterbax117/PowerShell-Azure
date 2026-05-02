<#
.SYNOPSIS
    Creates a Managed Disk from the latest (or a specified) Image Version in an
    Azure Compute Gallery, optionally across different subscriptions.

.PARAMETER DiskName
    Name of the Managed Disk to create in the target subscription.

.PARAMETER Location
    Azure region where the disk will be created. Example: eastus

.PARAMETER NewResourceGroup
    Resource Group in the target subscription that will contain the new disk.

.PARAMETER ComputeGalleryDefinitionName
    Image Definition name in the source Azure Compute Gallery.

.PARAMETER ComputeGalleryName
    Name of the source Azure Compute Gallery.

.PARAMETER ComputeGalleryResourceGroupName
    Resource Group that contains the source Azure Compute Gallery.

.PARAMETER ComputeGalleryVersion
    Specific image version to use (e.g. 1.0.2). Omit to use the latest version.

.PARAMETER RootGallerySub
    Subscription ID that contains the source Azure Compute Gallery.

.PARAMETER MyGallerySub
    Subscription ID where the new Managed Disk will be created.

.EXAMPLE
    .\Create-VM-Disk-From-Gallery-Image.ps1 `
        -DiskName 'MyWorkload-Disk' `
        -Location 'eastus' `
        -NewResourceGroup '<your-resource-group>' `
        -ComputeGalleryDefinitionName 'Win2019-Base' `
        -ComputeGalleryName 'E1ACG1' `
        -ComputeGalleryResourceGroupName '<your-resource-group>' `
        -RootGallerySub '<source-subscription-id>' `
        -MyGallerySub '<target-subscription-id>'
#>

[CmdletBinding()]
param(
    # Name of the disk you want to create in your subscription
    [Parameter(Mandatory = $true)]
    [string]$DiskName,

    # Azure location where the disk will be created
    [Parameter(Mandatory = $true)]
    [string]$Location,

    # Resource Group in the target subscription for the new disk
    [Parameter(Mandatory = $true)]
    [string]$NewResourceGroup,

    # Image Definition name in the source Compute Gallery
    [Parameter(Mandatory = $true)]
    [string]$ComputeGalleryDefinitionName,

    # Source Compute Gallery name
    [Parameter(Mandatory = $true)]
    [string]$ComputeGalleryName,

    # Resource Group containing the source Compute Gallery
    [Parameter(Mandatory = $true)]
    [string]$ComputeGalleryResourceGroupName,

    # Specific image version — leave blank to use the latest version
    [Parameter(Mandatory = $false)]
    [string]$ComputeGalleryVersion = '',

    # Subscription ID containing the source Compute Gallery
    [Parameter(Mandatory = $true)]
    [string]$RootGallerySub,

    # Subscription ID where the new Managed Disk will be created
    [Parameter(Mandatory = $true)]
    [string]$MyGallerySub
)

$ErrorActionPreference = 'Stop'

# Set context to the subscription that contains the source image
# (the account needs at least Reader access on the gallery image)
Write-Host "Switching to source gallery subscription..." -ForegroundColor Cyan
Set-AzContext -Subscription $RootGallerySub

if ($ComputeGalleryVersion) {
    # A specific version was requested — retrieve it directly
    $ImageVersion = Get-AzGalleryImageVersion `
        -GalleryImageDefinitionName $ComputeGalleryDefinitionName `
        -GalleryName $ComputeGalleryName `
        -ResourceGroupName $ComputeGalleryResourceGroupName `
        -Name $ComputeGalleryVersion
} else {
    # No version specified — get all versions and pick the latest using semantic version sort
    Write-Host "No version specified — finding latest image version..." -ForegroundColor Cyan
    $allVersions = Get-AzGalleryImageVersion `
        -GalleryImageDefinitionName $ComputeGalleryDefinitionName `
        -GalleryName $ComputeGalleryName `
        -ResourceGroupName $ComputeGalleryResourceGroupName |
        Select-Object -ExpandProperty Name

    # Sort using [version] cast for correct semantic versioning (e.g. 1.0.10 > 1.0.9)
    $latestVersionName = ($allVersions | Sort-Object { [version]$_ } | Select-Object -Last 1)

    Write-Host "Latest version found: $latestVersionName" -ForegroundColor Green

    $ImageVersion = Get-AzGalleryImageVersion `
        -GalleryImageDefinitionName $ComputeGalleryDefinitionName `
        -GalleryName $ComputeGalleryName `
        -ResourceGroupName $ComputeGalleryResourceGroupName `
        -Name $latestVersionName
}

$imageID = $ImageVersion.Id
Write-Host "Using image version ID: $imageID" -ForegroundColor Green

# Switch context to the subscription where the new disk will be created
Write-Host "Switching to target subscription..." -ForegroundColor Cyan
Set-AzContext -Subscription $MyGallerySub

# Creates a Disk Configuration for a Managed Disk using the Image Version in the Compute Gallery
$DiskConfig = New-AzDiskConfig `
    -Location $Location `
    -CreateOption 'FromImage' `
    -GalleryImageReference @{Id = $imageID}

# Creates a Managed Disk using the Image Version in the Compute Gallery
Write-Host "Creating managed disk '$DiskName' in resource group '$NewResourceGroup'..." -ForegroundColor Cyan
New-AzDisk -DiskName $DiskName `
    -Disk $DiskConfig `
    -ResourceGroupName $NewResourceGroup

Write-Host "Done. Managed disk '$DiskName' created successfully." -ForegroundColor Green
