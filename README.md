# PowerShell-Azure

A collection of PowerShell scripts for automating common Azure management tasks.

## Repository structure

- `runbooks/`: production Azure Automation scripts
- `scripts/`: ad-hoc utility scripts for local use
- `Azure/`: Azure resource management scripts (VMs, disks, galleries, costs, Key Vault)
- `Security/`: security and compliance scripts (TLS auditing, file scanning)
- `Utilities/`: general-purpose helper modules and scripts
- `docs/`: supplemental documentation and operational notes

## Scripts

| Script | Path | Purpose | Typical Run Context |
|---|---|---|---|
| Auto-Start-Stop-VMs.ps1 | runbooks/Auto-Start-Stop-VMs.ps1 | Starts or stops Azure VMs based on tags and action (Start/Stop). | Azure Automation Runbook (Managed Identity) |
| Azure-Arc-Automation-License-Assign.ps1 | runbooks/Azure-Arc-Automation-License-Assign.ps1 | Assigns ESU licenses for eligible Arc Windows Server 2012 machines and clears ESU profile for non-eligible connected machines. | Azure Automation Runbook (Managed Identity) |
| Get-TenantID-From-SubscriptionID.ps1 | scripts/Get-TenantID-From-SubscriptionID.ps1 | Returns the Azure AD Tenant ID for a given Subscription ID without authentication. | Local PowerShell |
| New-DemoStorageAccount.ps1 | scripts/New-DemoStorageAccount.ps1 | Creates a Storage Account with secure defaults, assigns RBAC to the signed-in principal, and uploads sample blob data. | Local PowerShell (Az module) |
| Create-VM-Disk-From-Gallery-Image.ps1 | Azure/Create-VM-Disk-From-Gallery-Image.ps1 | Creates a Managed Disk from the latest (or specified) image version in an Azure Compute Gallery, optionally across subscriptions. | Local PowerShell (Az module) |
| Export-AzureComputeGalleryImageVersion.ps1 | Azure/Export-AzureComputeGalleryImageVersion.ps1 | Exports an Image Version from an Azure Compute Gallery as a local VHD file. | Local PowerShell (Az module) |
| Import-AzureComputeGalleryImageVersion.ps1 | Azure/Import-AzureComputeGalleryImageVersion.ps1 | Imports a VHD into an Azure Compute Gallery as a new Image Version. | Local PowerShell (Az module) |
| Report-KeyVault-Azure.ps1 | Azure/Report-KeyVault-Azure.ps1 | Reports on all Key Vaults across accessible subscriptions including secret counts and nearest expiry. | Local PowerShell (Az module) |
| Get-Costs.ps1 | Azure/Get-Costs.ps1 | Reports Azure resource usage and costs for a subscription via the Consumption REST API. | Local PowerShell (Az module) |
| Get-TLS-Settings.ps1 | Security/Get-TLS-Settings.ps1 | Audits TLS/SCHANNEL and .NET cryptography registry settings across one or more remote Windows servers. | Local PowerShell (WinRM to targets) |
| Scan-Zip-Files.ps1 | Security/Scan-Zip-Files.ps1 | Moves ZIP files through a secure scan pipeline: source → staging → Windows Defender scan → archive. | Local PowerShell / Scheduled Task |
| Logging_Functions.psm1 | Utilities/Logging_Functions.psm1 | Reusable logging module that writes to a structured log file. Import into other scripts. | PowerShell Module (Import-Module) |
| Resolve-DNS-Loop.ps1 | Utilities/Resolve-DNS-Loop.ps1 | Continuously resolves DNS names against specific nameservers with timestamped output and optional CSV export. | Local PowerShell |

---

## Auto-Start-Stop-VMs.ps1

Automatically starts or stops Azure Virtual Machines based on resource tags. Designed to run as an Azure Automation runbook using a Managed Identity, enabling scheduled cost savings by powering VMs on and off at specific times.

### How it works

1. Authenticates to Azure using a system-assigned Managed Identity.
2. Queries VMs with a specified tag name and value.
3. Retrieves current power state for matching VMs.
4. Starts or stops VMs based on the Action parameter.

### Parameters

| Parameter | Required | Description | Example |
|---|---|---|---|
| Action | Yes | Start or Stop | Stop |
| TagName | Yes | Tag name used to filter VMs | AutoShutDownTime |
| TagValue | Yes | Tag value to match (24-hour format) | 1900 |

### Example usage

```powershell
# Stop all VMs tagged for shutdown at 7 PM
.\runbooks\Auto-Start-Stop-VMs.ps1 -Action "Stop" -TagName "AutoShutDownTime" -TagValue "1900"

# Start all VMs tagged for startup at 7 AM
.\runbooks\Auto-Start-Stop-VMs.ps1 -Action "Start" -TagName "AutoStartTime" -TagValue "0700"
```

---

## Azure-Arc-Automation-License-Assign.ps1

Manages Azure Arc ESU assignments using ARM REST APIs and system-assigned managed identity.

### What it does

1. Loads Arc licenses for Windows Server 2012.
2. Enumerates Arc machines in the target resource group.
3. Assigns an ESU license to connected Windows Server 2012 machines that are not assigned.
4. Clears ESU profile for connected non-2012 machines and sets software assurance to true.
5. Supports retry logic for throttling/transient errors and supports -WhatIf for dry runs.

### Key parameters

| Parameter | Required | Description |
|---|---|---|
| ArcLicenseRG | No | Resource group containing Arc license resources. |
| ArcMachinesRg | No | Resource group containing Arc machine resources. |
| SubscriptionId | No | Target Azure subscription ID (GUID format). |
| ApiVersion | No | ARM API version for Microsoft.HybridCompute endpoints. |

### Example usage

```powershell
# Dry run first
.\runbooks\Azure-Arc-Automation-License-Assign.ps1 -WhatIf

# Run with explicit resource groups and subscription
.\runbooks\Azure-Arc-Automation-License-Assign.ps1 -ArcLicenseRG "ArcLicenses-RG" -ArcMachinesRg "ArcServers-RG" -SubscriptionId "00000000-0000-0000-0000-000000000000"
```

### Credits

Big thanks to [Sean Greenbaum](https://github.com/SeanGreenbaum) for the original idea and baseline implementation that this script is built on.

---

## Get-TenantID-From-SubscriptionID.ps1

Returns the Azure AD Tenant ID for one or more Azure Subscription IDs by inspecting the WWW-Authenticate header returned by an unauthenticated call to the ARM endpoint. No credentials or Az module required.

### Key parameters

| Parameter | Required | Description |
|---|---|---|
| SubscriptionId | Yes | One or more Azure Subscription IDs (GUID). Accepts pipeline input. |

### Example usage

```powershell
# Single subscription
.\scripts\Get-TenantID-From-SubscriptionID.ps1 -SubscriptionId '00000000-0000-0000-0000-000000000000'

# Multiple subscriptions via pipeline
'sub1-guid','sub2-guid' | .\scripts\Get-TenantID-From-SubscriptionID.ps1
```

---

## New-DemoStorageAccount.ps1

Creates an Azure Storage Account with secure defaults (TLS 1.2, HTTPS only, public blob access disabled), assigns the `Storage Blob Data Contributor` role to the signed-in principal at the storage account scope, and uploads a configurable number of sample files using AAD-based data plane access. Supports `-WhatIf` and `-Confirm`.

### Key parameters

| Parameter | Required | Description |
|---|---|---|
| SubscriptionId | No | Azure Subscription ID. Defaults to current Az context. |
| ResourceGroupName | No | Resource group to create or reuse. |
| Location | No | Azure region (default: centralus). |
| StorageAccountName | No | 3-24 lowercase alphanumeric. Generated if omitted. |
| ContainerName | No | Blob container name (default: sample-data). |
| FileCount | No | Number of sample files (default: 10). |
| FileSizeKB | No | Approximate file size in KB (default: 4). |

### Example usage

```powershell
# Defaults
.\scripts\New-DemoStorageAccount.ps1

# Specific RG and region with verbose output
.\scripts\New-DemoStorageAccount.ps1 -ResourceGroupName "rg-demo" -Location "eastus2" -FileCount 25 -Verbose

# Preview only
.\scripts\New-DemoStorageAccount.ps1 -WhatIf
```

---

## Create-VM-Disk-From-Gallery-Image.ps1

Creates a Managed Disk from the latest (or a specified) image version in an Azure Compute Gallery. Supports cross-subscription scenarios where the gallery and the target disk reside in different subscriptions.

### Key parameters

| Parameter | Required | Description |
|---|---|---|
| DiskName | Yes | Name of the Managed Disk to create. |
| Location | Yes | Azure region where the disk will be created. |
| NewResourceGroup | Yes | Resource Group for the new disk. |
| ComputeGalleryName | Yes | Name of the source Azure Compute Gallery. |
| ComputeGalleryDefinitionName | Yes | Image Definition name in the gallery. |
| ComputeGalleryResourceGroupName | Yes | Resource Group containing the gallery. |
| RootGallerySub | Yes | Subscription ID containing the gallery. |
| MyGallerySub | Yes | Subscription ID where the new disk will be created. |
| ComputeGalleryVersion | No | Specific image version (e.g. `1.0.2`). Omit to use latest. |

### Example usage

```powershell
.\Azure\Create-VM-Disk-From-Gallery-Image.ps1 `
    -DiskName "my-disk" `
    -Location "eastus" `
    -NewResourceGroup "rg-disks" `
    -ComputeGalleryName "MyGallery" `
    -ComputeGalleryDefinitionName "WinServer2022" `
    -ComputeGalleryResourceGroupName "rg-gallery" `
    -RootGallerySub "source-sub-guid" `
    -MyGallerySub "target-sub-guid"
```

---

## Export-AzureComputeGalleryImageVersion.ps1

Exports an Image Version from an Azure Compute Gallery as a VHD file on disk. Creates a temporary Managed Disk, generates a time-limited SAS URI, downloads the VHD locally, then revokes the SAS and deletes the temporary disk — even if the download fails.

### Example usage

```powershell
.\Azure\Export-AzureComputeGalleryImageVersion.ps1
```

> Prompts for gallery name, image definition, version, and local output path.

---

## Import-AzureComputeGalleryImageVersion.ps1

Imports a previously downloaded VHD as a new Image Version in an Azure Compute Gallery. Validates the VHD using an auto-generated MD5 hash. Creates the gallery and image definition if they do not exist. Deletes the temporary Managed Disk once the import completes.

### Example usage

```powershell
.\Azure\Import-AzureComputeGalleryImageVersion.ps1
```

> Prompts for VHD path, gallery name, image definition, and version details.

---

## Report-KeyVault-Azure.ps1

Iterates through every Azure subscription the signed-in account has access to, enumerates all Key Vaults, and reports the vault name, resource group, subscription, total secret count, and the nearest expiry date. Vaults where access is denied are skipped with a warning rather than terminating the script. Results can optionally be exported to a timestamped CSV.

### Prerequisites

- Active Az context (`Connect-AzAccount`)
- Key Vault Reader + Key Vault Secrets User (or equivalent) on each vault

### Example usage

```powershell
# Console output only
.\Azure\Report-KeyVault-Azure.ps1

# Export to CSV
.\Azure\Report-KeyVault-Azure.ps1 -OutputCsv .\keyvault-report.csv
```

---

## Get-Costs.ps1

Queries the Azure Consumption / Usage Details API for the specified subscription and date range, handling all response pagination automatically. Outputs a grouped summary by Meter Category and a full per-row detail table. Optionally exports to CSV.

### Key parameters

| Parameter | Required | Description |
|---|---|---|
| SubscriptionId | No | Azure Subscription ID. Defaults to current Az context. |
| StartDate | No | Inclusive start date (`yyyy-MM-dd`). Defaults to first of current month. |
| EndDate | No | Inclusive end date (`yyyy-MM-dd`). Defaults to today. |
| OutputCsv | No | Path for CSV export of the full result set. |

### Example usage

```powershell
# Current month costs
.\Azure\Get-Costs.ps1

# Specific date range with CSV export
.\Azure\Get-Costs.ps1 -StartDate 2024-03-01 -EndDate 2024-03-31 -OutputCsv .\march-costs.csv

# Specific subscription
.\Azure\Get-Costs.ps1 -SubscriptionId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
```

---

## Get-TLS-Settings.ps1

Audits TLS/SCHANNEL protocol settings and .NET Framework cryptography registry keys on one or more Windows servers using a single WinRM round-trip per server. Checks TLS 1.0, 1.1, 1.2 (client & server), WinHTTP defaults, and .NET Framework `SystemDefaultTlsVersions` / `SchUseStrongCrypto` settings.

### Key parameters

| Parameter | Required | Description |
|---|---|---|
| Servers | No | One or more server names or IP addresses. Default: current machine. |

### Example usage

```powershell
# Audit local machine
.\Security\Get-TLS-Settings.ps1

# Audit multiple servers
.\Security\Get-TLS-Settings.ps1 -Servers "server1","server2","server3"
```

---

## Scan-Zip-Files.ps1

Implements a secure three-stage file handling pipeline for ZIP archives: **Move → Defender Scan → Archive**. Logs all activity to both the Windows Application Event Log and a local text file. Designed to run as a scheduled task or part of a file-intake automation pipeline.

### Key parameters

| Parameter | Required | Description |
|---|---|---|
| sourcePath | Yes | Path (with wildcard) pointing to incoming ZIP files. |
| moveToPath | Yes | Staging path where files are moved for scanning. |
| processPath | Yes | Staging path with wildcard for post-scan processing. |
| completePath | Yes | Archive path for clean files after passing the scan. |

### Prerequisites

- Windows Defender (`MpCmdRun`) — available by default on Windows 10/11 and Server 2016+

### Example usage

```powershell
.\Security\Scan-Zip-Files.ps1 `
    -sourcePath "C:\intake\incoming\*" `
    -moveToPath "C:\intake\process\" `
    -processPath "C:\intake\process\*" `
    -completePath "C:\intake\complete\"
```

---

## Logging_Functions.psm1

A reusable PowerShell module that provides structured logging functions for use in other scripts. Creates a log file with a specified path and name, initialises it with run metadata, and exposes functions for writing info, warning, and error entries.

### Usage

```powershell
# Import the module
Import-Module .\Utilities\Logging_Functions.psm1

# Start a log file
Log-Start -LogPath "C:\logs" -LogName "MyScript.log" -ScriptVersion "1.0"

# Write entries
Log-Write -LineValue "Processing started"
Log-Error -LineValue "Something went wrong"

# Close the log
Log-Finish -LineValue "Processing complete"
```

---

## Resolve-DNS-Loop.ps1

Continuously resolves one or more DNS names against a configurable list of nameservers at a set interval. Writes timestamped results to the pipeline (enabling `Export-Csv` piping) and optionally appends to a CSV file directly. Use Ctrl+C to stop, or pass `-RunOnce` for a single-pass check.

### Key parameters

| Parameter | Required | Description |
|---|---|---|
| Domains | No | One or more DNS names to resolve. Default: `example.com`. |
| Servers | No | DNS servers to query. Default: `8.8.8.8`, `8.8.4.4`. |
| IntervalSeconds | No | Seconds between resolution rounds. Default: 5. |
| OutputCsv | No | Path to append results to a CSV file. |
| RunOnce | No | Switch. Run one pass and exit instead of looping. |

### Example usage

```powershell
# Monitor DNS propagation for a domain
.\Utilities\Resolve-DNS-Loop.ps1 -Domains 'contoso.com','mail.contoso.com' -IntervalSeconds 10

# Single-pass check with table output
.\Utilities\Resolve-DNS-Loop.ps1 -Domains 'contoso.com' -RunOnce | Format-Table

# Log to CSV
.\Utilities\Resolve-DNS-Loop.ps1 -Domains 'contoso.com' -OutputCsv .\dns_log.csv
```

---

## Prerequisites

- Azure Automation account with system-assigned managed identity (for runbooks).
- Active Az PowerShell context (`Connect-AzAccount`) for Azure management scripts.
- Required Azure RBAC to read/update target resources.
- Network access to `https://management.azure.com/` from run context.
- WinRM connectivity to target servers for `Get-TLS-Settings.ps1`.
- Windows Defender module (`MpCmdRun`) for `Scan-Zip-Files.ps1`.