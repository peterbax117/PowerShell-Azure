# PowerShell-Azure

A collection of PowerShell scripts for automating common Azure management tasks.

## Repository structure

- runbooks/: production Azure Automation scripts
- scripts/: ad-hoc utility scripts for local use
- docs/: supplemental documentation and operational notes

## Scripts

| Script | Path | Purpose | Typical Run Context |
|---|---|---|---|
| Auto-Start-Stop-VMs.ps1 | runbooks/Auto-Start-Stop-VMs.ps1 | Starts or stops Azure VMs based on tags and action (Start/Stop). | Azure Automation Runbook (Managed Identity) |
| Azure-Arc-Automation-License-Assign.ps1 | runbooks/Azure-Arc-Automation-License-Assign.ps1 | Assigns ESU licenses for eligible Arc Windows Server 2012 machines and clears ESU profile for non-eligible connected machines. | Azure Automation Runbook (Managed Identity) |
| Get-TenantID-From-SubscriptionID.ps1 | scripts/Get-TenantID-From-SubscriptionID.ps1 | Returns the Azure AD Tenant ID for a given Subscription ID without authentication. | Local PowerShell |
| New-DemoStorageAccount.ps1 | scripts/New-DemoStorageAccount.ps1 | Creates a Storage Account with secure defaults, assigns RBAC to the signed-in principal, and uploads sample blob data. | Local PowerShell (Az module) |

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

## Prerequisites

- Azure Automation account with system-assigned managed identity (for runbooks).
- Required Azure RBAC to read/update target resources.
- Network access to https://management.azure.com/ from run context.
