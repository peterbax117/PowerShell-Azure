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
# Get 
$AzureContext = Set-AzContext -SubscriptionName $AzureContext.Subscription -DefaultProfile $AzureContext

## Get all virtual machines
Write-Output ""
Write-Output ""
Write-Output "---------------------------- Status ----------------------------"
Write-Output "Getting all virtual machines from all resource groups with Tag: $TagName set to value: $TagValue ..."

$instances = Get-AzResource -TagName $TagName -TagValue $TagValue -ResourceType "Microsoft.Compute/virtualMachines"
$resourceGroupsContent = @()
if ($instances)
{

    $instances | ForEach-Object {
        $instance = $_
        $instancePowerState = (((Get-AzVM -ResourceGroupName $($instance.ResourceGroupName) -Name $($instance.Name) -Status).Statuses.Code[1]) -replace "PowerState/", "")

        $resourceGroupContent = New-Object -Type PSObject -Property @{
            "Instance name" = $($instance.Name)
            "Resource group name" = $($instance.ResourceGroupName)
            "Instance state" = ([System.Threading.Thread]::CurrentThread.CurrentCulture.TextInfo.ToTitleCase($instancePowerState))
            }
            $resourceGroupsContent += $resourceGroupContent
    }    
}
$resourceGroupsContent

$runningInstances = ($resourceGroupsContent | Where-Object {$_.("Instance state") -eq "Running" -or $_.("Instance state") -eq "Starting"})
$deallocatedInstances = ($resourceGroupsContent | Where-Object {$_.("Instance state") -eq "Deallocated" -or $_.("Instance state") -eq "Deallocating"})

## Updating virtual machines power state
if (($runningInstances) -and ($Action -eq "Stop"))
{
    Write-Output "--------------------------- Updating ---------------------------"
    Write-Output "Trying to stop virtual machines ..."

    $runningInstances | ForEach-Object -parallel {
        $runningInstance = $_
        Write-Output "$($runningInstance.("Instance name")) is shutting down ..."
        $startTime = Get-Date -Format G
        Stop-AzVM -ResourceGroupName $($runningInstance.("Resource group name")) -Name $($runningInstance.("Instance name")) -Force
        $endTime = Get-Date -Format G
        $updateStatus = New-Object -Type PSObject -Property @{
            "Instance name" = $($runningInstance.("Instance name"))
            "Resource group name" = $($runningInstance.("Resource group name"))
            "Start time" = $startTime
            "End time" = $endTime
        }
        $updateStatus
    }
}
elseif (($deallocatedInstances) -and ($Action -eq "Start"))
{
    Write-Output "--------------------------- Updating ---------------------------"
    Write-Output "Trying to start virtual machines ..."

    $deallocatedInstances | ForEach-Object -parallel {                                    
            $deallocatedInstance = $_
            Write-Output "$($deallocatedInstance.("Instance name")) is starting ..."
            $startTime = Get-Date -Format G
            Start-AzVM -ResourceGroupName $($deallocatedInstance.("Resource group name")) -Name $($deallocatedInstance.("Instance name"))
            $endTime = Get-Date -Format G
            $updateStatus = New-Object -Type PSObject -Property @{
                "Instance name" = $($deallocatedInstance.("Instance name"))
                "Resource group name" = $($deallocatedInstance.("Resource group name"))
                "Start time" = $startTime
                "End time" = $endTime
            }
        $updateStatus
    }
}
#### End of updating virtual machines power state