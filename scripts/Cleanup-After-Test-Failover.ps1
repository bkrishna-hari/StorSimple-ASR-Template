<#
.DESCRIPTION
    This runbook acts as a cleanup script for the Test Failover scenario
    This runbook deletes all the volumes, backups, backup policies and volume contaienrs on the target device.
    This runbook also shuts down the SVA after the manual action in case of a Test Failover
    
.ASSETS (The following need to be stored as Automation Assets)
    [You can choose to encrypt these assets ]
    
    AzureCredential [Windows PS Credential]:
        A credential containing an Org Id username / password with access to this Azure subscription
        Multi Factor Authentication must be disabled for this credential

    The following have to be added with the Recovery Plan Name as a prefix, eg - TestPlan-StorSimRegKey [where TestPlan is the name of the recovery plan]
    [All these are String variables]

    'RecoveryPlanName'-AzureSubscriptionName: The name of the Azure Subscription
    'RecoveryPlanName'-StorSimRegKey: The registration key for the StorSimple manager
    'RecoveryPlanName'-ResourceName: The name of the StorSimple resource
    'RecoveryPlanName'-TargetDeviceName: The device on which the test failover was performed (the one which needs to be cleaned up)
    'RecoveryPlanName'-AutomationAccountName: The name of the Automation Account in which the various runbooks are stored
#>

workflow Cleanup-After-Test-Failover
{
    Param 
    ( 
        [parameter(Mandatory=$true)] 
        [Object]
        $RecoveryPlanContext
    )    
        
    $PlanName = $RecoveryPlanContext.RecoveryPlanName
    
    $cred = Get-AutomationPSCredential -Name "AzureCredential"
    if ($cred -eq $null)
    {
        throw "The AzureCredential asset has not been created in the Automation service."
    }
    
    $SubscriptionName = Get-AutomationVariable -Name "$PlanName-AzureSubscriptionName"
    if ($SubscriptionName -eq $null)
    {
        throw "The AzureSubscriptionName asset has not been created in the Automation service."
    }    
    
    $RegistrationKey = Get-AutomationVariable -Name "$PlanName-StorSimRegKey"
    if ($RegistrationKey -eq $null)
    {
        throw "The StorSimRegKey asset has not been created in the Automation service."
    }    
    
    $ResourceName = Get-AutomationVariable -Name "$PlanName-ResourceName" 
    if ($ResourceName -eq $null)
    {
        throw "The ResourceName asset has not been created in the Automation service."
    }    
     
    $TargetDeviceName = Get-AutomationVariable -Name "$PlanName-TargetDeviceName" 
    if ($TargetDeviceName -eq $null) 
    { 
          throw "The TargetDeviceName asset has not been created in the Automation service."
    }
    
    $TargetDeviceDnsName = Get-AutomationVariable -Name "$PlanName-TargetDeviceDnsName"      
    if ($TargetDeviceDnsName -eq $null) 
    { 
        throw "The TargetDeviceDnsName asset has not been created in the Automation service."  
    } 
    
    $TargetDeviceServiceName = $TargetDeviceDnsName.Replace(".cloudapp.net","")
    if ($TargetDeviceServiceName -eq $null)
    {
        throw "Invalid TargetDeviceDnsName"
    }

    $AutomationAccountName = Get-AutomationVariable -Name "$PlanName-AutomationAccountName"
    if ($AutomationAccountName -eq $null) 
    { 
        throw "The AutomationAccountName asset has not been created in the Automation service."  
    }

    # Stops the script at first exception
    # Setting this option to suspend if Azure-Login fails
    $ErrorActionPreference = "Stop"
    
    # Connect to Azure
    Write-Output "Connecting to Azure"
    try {
        $AzureAccount = Add-AzureAccount -Credential $cred      
        $AzureSubscription = Select-AzureSubscription -SubscriptionName $SubscriptionName          
        if (($AzureSubscription -eq $null) -or ($AzureAccount -eq $null))
        {
            throw "Unable to connect to Azure"
        }
    }
    catch {
        throw "Unable to connect to Azure"
    }
        
    $DummyAsset = Get-AutomationVariable -Name "$PlanName-DummyVMGUID"
    if ($DummyAsset -ne $null)
    {     
        $Result = Remove-AzureAutomationVariable -AutomationAccountName $AutomationAccountName -Name ($PlanName + "-DummyVMGUID") -Force       
    }
       
    if ($RecoveryPlanContext.FailoverType -eq "Test")
    {
        # Connect to the StorSimple Resource
        Write-Output "Connecting to StorSimple Resource $ResourceName"
        $StorSimpleResource = Select-AzureStorSimpleResource -ResourceName $ResourceName -RegistrationKey $RegistrationKey
        if ($StorSimpleResource -eq $null)
        {
            throw "Unable to connect to the StorSimple resource $ResourceName"
        }       
    
        $TargetDevice = Get-AzureStorSimpleDevice -DeviceName $TargetDeviceName
        if (($TargetDevice -eq $null) -or ($TargetDevice.Status -ne "Online"))
        {
            throw "Target device $TargetDeviceName does not exist or is not online"
        }
            
        $SLEEPTIMEOUT = 10    # Value in seconds
        $SLEEPLARGETIMEOUT = 300    # Value in seconds
        
        InlineScript
        {
            $TargetDeviceName = $Using:TargetDeviceName 
            $SLEEPTIMEOUT = $Using:SLEEPTIMEOUT
            $SLEEPLARGETIMEOUT = $Using:SLEEPLARGETIMEOUT
            
            Write-Output "Initiating cleanup of volumes, backups, backup policies"
            $VolumeContainers = Get-AzureStorSimpleDeviceVolumeContainer -DeviceName $TargetDeviceName
    
            if ($VolumeContainers -ne $null)
            { 
                foreach ($Container in $VolumeContainers) 
                {
                    $Volumes = Get-AzureStorSimpleDeviceVolume -DeviceName $TargetDeviceName -VolumeContainer $Container  
                    if ($Volumes -ne $null)
                    {
                        foreach ($Volume in $Volumes) 
                        {
                            $RetryCount = 0
                            while ($RetryCount -lt 2)
                            {
                                $isSuccessful = $true
                                $id = Set-AzureStorSimpleDeviceVolume -DeviceName $TargetDeviceName -VolumeName $Volume.Name -Online $false -WaitForComplete
                                if (($id -eq $null) -or ($id[0].TaskStatus -ne "Completed"))
                                {
                                    Write-Output ("Volume - $($Volume.Name) could not be taken offline")
                                    $isSuccessful = $false
                                }
                                else
                                {
                                    $id = Remove-AzureStorSimpleDeviceVolume -DeviceName $TargetDeviceName -VolumeName $Volume.Name -Force -WaitForComplete
                                    if (($id -eq $null) -or ($id.TaskStatus -ne "Completed"))
                                    {
                                        Write-Output ("Volume - $($Volume.Name) could not be deleted")
                                        $isSuccessful = $false
                                    }
                                    
                                }
                                if ($isSuccessful)
                                {
                                    Write-Output ("Volume - $($Volume.Name) deleted")
                                    break
                                }
                                else
                                {
                                    if ($RetryCount -eq 0)
                                    {
                                        Write-Output "Retrying for volumes deletion"
                                    }
                                    else
                                    {
                                        throw "Unable to delete Volume - $($Volume.Name)"
                                    }
                                                     
                                    Start-Sleep -s $SLEEPTIMEOUT
                                    $RetryCount += 1   
                                }
                            }
                        }
                    }
                }               
                
                Write-Output "Deleting backups"
                $RetryCount = 0
                while ($RetryCount -lt 2)
                {
                    $allSuccessful = $true
                    $ids = Get-AzureStorSimpleDeviceBackup -DeviceName $TargetDeviceName | Remove-AzureStorSimpleDeviceBackup -DeviceName $TargetDeviceName -Force -WaitForComplete
                    Start-Sleep $SLEEPTIMEOUT # Sleep to make sure that backups are really deleted

                    if ($ids -ne $null)
                    {
                        foreach ($id in $ids)
                        {
                            if ($id.Status -ne "Succeeded")
                            {
                                Write-Output "Unable to delete backup - JobID - $($id.TaskId)"
                                $allSuccessful = $false
                            }                              
                        }
                    }
                    if ($allSuccessful)
                    {
                        Write-Output "Backups deleted"
                        break
                    }
                    else
                    {
                        if ($RetryCount -eq 0)
                        {
                            Write-Output "Retrying for backups deletion"
                        }
                        else
                        {
                            throw "Unable to delete backup - JobID - $($id.TaskId)"
                        }
                        Start-Sleep -s $SLEEPTIMEOUT
                        $RetryCount += 1 
                    }
                } 
                   
                Write-Output "Deleting Backup Policies"
                $BackupPolicies = Get-AzureStorSimpleDeviceBackupPolicy -DeviceName $TargetDeviceName
                $PolicyIds =  $BackupPolicies.InstanceId   # Returns all Instance IDs
                
                if ($PolicyIds -ne $null)                    
                {
                    foreach ($id in $PolicyIds)
                    {
                        $RetryCount = 0
                        while ($RetryCount -lt 2)
                        {
                            $PolicyName = ($BackupPolicies | Where-Object {$_.InstanceId -eq $id}).Name
                            $Result = Remove-AzureStorSimpleDeviceBackupPolicy -DeviceName $TargetDeviceName -BackupPolicyId $id -Force -WaitForComplete
                                                        
                            if ($Result -eq $null -or $Result.TaskStatus -ne "Completed")
                            {
                                Write-Output "Backup policy - $PolicyName could not be deleted"
                                if ($RetryCount -eq 0)
                                {
                                    Write-Output "Retrying for Backup Policies deletion"
                                }
                                else
                                {
                                    throw "Unable to delete backup policy - $PolicyName"
                                }
                                Start-Sleep -s $SLEEPTIMEOUT
                                $RetryCount += 1                                
                            }
                            else
                            {
                                Write-Output "Backup policy - $PolicyName deleted"
                                break
                            }  
                        }      
                    }
                }

                Start-Sleep -s $SLEEPLARGETIMEOUT
                Write-Output "Deleting Volume Containers"
                foreach ($Container in $VolumeContainers) 
                {
                    $RetryCount = 0 
                    while ($RetryCount -lt 2)
                    {
                        $id = Remove-AzureStorSimpleDeviceVolumeContainer -DeviceName $TargetDeviceName -VolumeContainer $Container -Force -WaitForComplete
                        if ($id -eq $null -or $id.TaskStatus -ne "Completed")
                        {
                            Write-Output ("Volume Container - $($Container.Name) could not be deleted")   
                            if ($RetryCount -eq 0)
                            {
                                Write-Output "Retrying for volume container deletion"
                            }
                            else
                            {
                                throw "Unable to delete Volume Container - $($Container.Name)"
                            }
                            Start-Sleep -s $SLEEPLARGETIMEOUT
                            $RetryCount += 1
                        }
                        else
                        {
                            Write-Output ("Volume Container - $($Container.Name) deleted")
                            break
                        }
                    }
                }
            }
      }     
      
      Write-Output "Cleanup completed" 
      Write-Output "Attempting to shutdown the SVA"
      InlineScript
      {
          $TargetDeviceName = $Using:TargetDeviceName
          $TargetDeviceServiceName = $Using:TargetDeviceServiceName 
          $SLEEPTIMEOUT = $Using:SLEEPTIMEOUT
          
          $RetryCount = 0
          while ($RetryCount -lt 2)
          {   
              $Result = Stop-AzureVM -ServiceName $TargetDeviceServiceName -Name $TargetDeviceName -Force
              if ($Result.OperationStatus -eq "Succeeded")
              {
                  Write-Output "SVA succcessfully turned off"   
                  break
              }
              else
              {
                  if ($RetryCount -eq 0)
                  {
                      Write-Output "Retrying for SVA shutdown"
                  }
                  else
                  {
                      Write-Output "Unable to stop the SVA VM"
                  }
                                 
                  Start-Sleep -s $SLEEPTIMEOUT
                  $RetryCount += 1   
              }
          }
       }
    }
}