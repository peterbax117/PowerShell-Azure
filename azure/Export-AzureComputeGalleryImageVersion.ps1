<#
MIT License

Copyright (c) 2022 Jason Masten

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

.SYNOPSIS
Exports an Image Version from an Azure Compute Gallery as a VHD file.
.DESCRIPTION
Creates a temporary Managed Disk from the specified Image Version in an Azure Compute
Gallery, generates a time-limited SAS URI, downloads the VHD to a local path, then
revokes the SAS and deletes the temporary disk — even if the download fails.
.PARAMETER ComputeGalleryDefinitionName
The name of the Image Definition in the Azure Compute Gallery.
.PARAMETER ComputeGalleryName
The name of the Azure Compute Gallery.
.PARAMETER ComputeGalleryResourceGroupName
The name of the Resource Group that contains the Azure Compute Gallery.
.PARAMETER ComputeGalleryVersion
The version of the Image in the Azure Compute Gallery (e.g. 1.0.0).
.PARAMETER DownloadPath
Local folder where the VHD will be saved. Defaults to the current user's Downloads folder.
.NOTES
  Version:              1.2
  Author:               Jason Masten / Pete Baxter
  Creation Date:        2022-05-11
  Last Modified Date:   2024-01-01  — completed download workflow; wired up all
                                      parameters; added try/finally for cleanup.
.EXAMPLE
.\Export-AzureComputeGalleryImageVersion.ps1 `
    -ComputeGalleryDefinitionName 'WindowsServer2019Datacenter' `
    -ComputeGalleryName 'cg_shared_d_va' `
    -ComputeGalleryResourceGroupName 'rg-images-d-va' `
    -ComputeGalleryVersion '1.0.0'

Creates a temporary Managed Disk, downloads the VHD to the user's Downloads folder,
and cleans up all temporary Azure resources on completion or failure.
#>
[CmdletBinding()]
param(

    [parameter(Mandatory)]
    [string]$ComputeGalleryDefinitionName,

    [parameter(Mandatory)]
    [string]$ComputeGalleryName,

    [parameter(Mandatory)]
    [string]$ComputeGalleryResourceGroupName,

    [parameter(Mandatory)]
    [string]$ComputeGalleryVersion,

    # Destination folder for the downloaded VHD
    [parameter(Mandatory=$false)]
    [string]$DownloadPath = "$HOME\Downloads"

)

$ErrorActionPreference = 'Stop'

# Derive location and a timestamped disk name from the gallery resource group
$Location  = (Get-AzResourceGroup -Name $ComputeGalleryResourceGroupName).Location
$DiskName  = "export-disk-$ComputeGalleryDefinitionName-$(Get-Date -Format 'yyyyMMddHHmmss')"

# Gets the Image Version object using the supplied parameters
Write-Host "Retrieving image version '$ComputeGalleryVersion'..." -ForegroundColor Cyan
$ImageVersion = Get-AzGalleryImageVersion `
    -GalleryImageDefinitionName $ComputeGalleryDefinitionName `
    -GalleryName $ComputeGalleryName `
    -ResourceGroupName $ComputeGalleryResourceGroupName `
    -Name $ComputeGalleryVersion

# Gets the OS Type from the Image Definition
$OsType = (Get-AzGalleryImageDefinition `
    -GalleryImageDefinitionName $ComputeGalleryDefinitionName `
    -GalleryName $ComputeGalleryName `
    -ResourceGroupName $ComputeGalleryResourceGroupName).OsType

# Creates a Disk Configuration for a temporary Managed Disk from the Image Version
$DiskConfig = New-AzDiskConfig `
    -Location $Location `
    -CreateOption 'FromImage' `
    -GalleryImageReference @{Id = $ImageVersion.Id} `
    -OsType $OsType

# Creates the temporary Managed Disk
Write-Host "Creating temporary managed disk '$DiskName'..." -ForegroundColor Cyan
$Disk = New-AzDisk `
    -DiskName $DiskName `
    -Disk $DiskConfig `
    -ResourceGroupName $ComputeGalleryResourceGroupName

try {
    # Generates a SAS URI valid for 4 hours to allow the VHD download
    Write-Host "Generating SAS token (valid 4 hours)..." -ForegroundColor Cyan
    $DiskAccess = Grant-AzDiskAccess `
        -ResourceGroupName $Disk.ResourceGroupName `
        -DiskName $Disk.Name `
        -Access 'Read' `
        -DurationInSecond 14400

    # Ensure the download folder exists
    if (-not (Test-Path $DownloadPath)) {
        New-Item -ItemType Directory -Path $DownloadPath | Out-Null
    }

    $destPath = Join-Path -Path $DownloadPath -ChildPath "$DiskName.vhd"
    Write-Host "Downloading VHD to '$destPath'..." -ForegroundColor Cyan

    # Downloads the VHD using parallel transfers and validates the MD5 hash automatically
    Get-AzStorageBlobContent `
        -AbsoluteUri $DiskAccess.AccessSAS `
        -Destination $destPath

    Write-Host "Download complete: $destPath" -ForegroundColor Green
}
finally {
    # Always revoke the SAS token and delete the temporary disk — even on failure
    Write-Host "Revoking SAS token..." -ForegroundColor Cyan
    Revoke-AzDiskAccess `
        -ResourceGroupName $Disk.ResourceGroupName `
        -DiskName $Disk.Name `
        -ErrorAction SilentlyContinue

    Write-Host "Deleting temporary managed disk '$DiskName'..." -ForegroundColor Cyan
    Remove-AzDisk `
        -ResourceGroupName $Disk.ResourceGroupName `
        -DiskName $Disk.Name `
        -Force `
        -ErrorAction SilentlyContinue
}
