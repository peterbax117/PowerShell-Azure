<# 
    Parameters

    Action == 'Start' or 'Stop'
    TagName == 'AutoStartTime' or 'AutoShutDownTime'
    TagValue == 24 hour format such as '0700' or '2200'

#>
param (

    [Parameter(Mandatory=$true)][String] $Action,
    [Parameter(Mandatory=$true)][String] $TagName,
    [Parameter(Mandatory=$true)][String] $TagValue
)

# Disable the Az Context Autosave
Disable-AzContextAutosave -Scope Process

# Get the current Az Context
$AzureContext = (Connect-AzAccount -Identity).Context
$AzureContext = Set-AzContext -SubscriptionName $AzureContext.Subscription -DefaultProfile $AzureContext

## Get all virtual machines
Write-Output ""
Write-Output ""
Write-Output "---------------------------- Status ----------------------------"
Write-Output "Getting all virtual machines from all resource groups with Tag: $TagName set to value: $TagValue ..."

$instances = Get-AzResource -TagName $TagName -TagValue $TagValue -ResourceType "Microsoft.Compute/virtualMachines"

if ($instances)
{
    # Fetch VM power states in parallel instead of sequentially
    $resourceGroupsContent = $instances | ForEach-Object -Parallel {
        $instance = $_
        $instancePowerState = (((Get-AzVM -ResourceGroupName $instance.ResourceGroupName -Name $instance.Name -Status).Statuses.Code[1]) -replace "PowerState/", "")

        [PSCustomObject]@{
            "Instance name"       = $instance.Name
            "Resource group name" = $instance.ResourceGroupName
            "Instance state"      = (Get-Culture).TextInfo.ToTitleCase($instancePowerState)
        }
    } -ThrottleLimit 10
}
else
{
    $resourceGroupsContent = @()
}

$resourceGroupsContent

$runningInstances = @($resourceGroupsContent | Where-Object { $_."Instance state" -in "Running", "Starting" })
$deallocatedInstances = @($resourceGroupsContent | Where-Object { $_."Instance state" -in "Deallocated", "Deallocating" })

## Updating virtual machines power state
if ($runningInstances.Count -gt 0 -and $Action -eq "Stop")
{
    Write-Output "--------------------------- Updating ---------------------------"
    Write-Output "Trying to stop virtual machines ..."

    $runningInstances | ForEach-Object -Parallel {
        $vm = $_
        Write-Output "$($vm."Instance name") is shutting down ..."
        $startTime = Get-Date -Format G
        Stop-AzVM -ResourceGroupName $vm."Resource group name" -Name $vm."Instance name" -Force
        $endTime = Get-Date -Format G
        [PSCustomObject]@{
            "Instance name"       = $vm."Instance name"
            "Resource group name" = $vm."Resource group name"
            "Start time"          = $startTime
            "End time"            = $endTime
        }
    } -ThrottleLimit 10
}
elseif ($deallocatedInstances.Count -gt 0 -and $Action -eq "Start")
{
    Write-Output "--------------------------- Updating ---------------------------"
    Write-Output "Trying to start virtual machines ..."

    $deallocatedInstances | ForEach-Object -Parallel {
        $vm = $_
        Write-Output "$($vm."Instance name") is starting ..."
        $startTime = Get-Date -Format G
        Start-AzVM -ResourceGroupName $vm."Resource group name" -Name $vm."Instance name"
        $endTime = Get-Date -Format G
        [PSCustomObject]@{
            "Instance name"       = $vm."Instance name"
            "Resource group name" = $vm."Resource group name"
            "Start time"          = $startTime
            "End time"            = $endTime
        }
    } -ThrottleLimit 10
}
#### End of updating virtual machines power state