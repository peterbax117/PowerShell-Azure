# PowerShell-Azure

A collection of PowerShell scripts for automating common Azure management tasks.

## Repository structure

- runbooks/: production Azure Automation scripts
- docs/: supplemental documentation and operational notes

## Scripts

| Script | Path | Purpose | Typical Run Context |
|---|---|---|---|
| Auto-Start-Stop-VMs.ps1 | runbooks/Auto-Start-Stop-VMs.ps1 | Starts or stops Azure VMs based on tags and action (Start/Stop). | Azure Automation Runbook (Managed Identity) |
| Azure-Arc-Automation-License-Assign.ps1 | runbooks/Azure-Arc-Automation-License-Assign.ps1 | Assigns ESU licenses for eligible Arc Windows Server 2012 machines and clears ESU profile for non-eligible connected machines. | Azure Automation Runbook (Managed Identity) |

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

## Prerequisites

- Azure Automation account with system-assigned managed identity.
- Required Azure RBAC to read/update target resources.
- Network access to https://management.azure.com/ from run context.
