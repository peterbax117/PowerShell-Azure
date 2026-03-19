# PowerShell-Azure

A collection of PowerShell scripts for automating common Azure management tasks.

## Auto-Start-Stop-VMs.ps1

Automatically starts or stops Azure Virtual Machines based on resource tags. Designed to run as an Azure Automation runbook using a Managed Identity, enabling scheduled cost savings by powering VMs on and off at specific times.

### How it works

1. Authenticates to Azure using a system-assigned Managed Identity.
2. Queries all VMs that have a specified tag name and value (e.g., `AutoShutDownTime = 1900`).
3. Retrieves the current power state of each matching VM in parallel.
4. Starts or stops the VMs depending on the `Action` parameter, processing them concurrently for speed.

### Parameters

| Parameter | Required | Description | Example |
|-----------|----------|-------------|---------|
| `Action` | Yes | `Start` or `Stop` | `Stop` |
| `TagName` | Yes | The tag name to filter VMs by | `AutoShutDownTime` |
| `TagValue` | Yes | The tag value to match (24-hour format) | `1900` |

### Example usage

```powershell
# Stop all VMs tagged for shutdown at 7 PM
.\Auto-Start-Stop-VMs.ps1 -Action "Stop" -TagName "AutoShutDownTime" -TagValue "1900"

# Start all VMs tagged for startup at 7 AM
.\Auto-Start-Stop-VMs.ps1 -Action "Start" -TagName "AutoStartTime" -TagValue "0700"
```

### Prerequisites

- Az PowerShell module (`Az.Accounts`, `Az.Compute`, `Az.Resources`)
- Azure Automation account with a system-assigned Managed Identity
- VMs tagged with the appropriate tag name and value
