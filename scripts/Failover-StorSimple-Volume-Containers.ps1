<#
.DESCRIPTION
    This runbook performs a failover of the StorSimple volume containers corresponding to the particular Azure Site Recovery failover.
    Unplanned failover - The specified volume containers are failed over to the target Device
    Planned failover - Backups of all the volumes in the volume containers are taken based on the backup policies which were last used to take a successful backup and then the volume containers are failed over on to the Target Device
    Test failover - All the volumes in the volume containers are cloned on to the target Device
    Failback - It performs the same steps as in the case of a planned failover with the Source Device and Target Device swapped
     
.ASSETS 
    [You can choose to encrypt these assets ]
    
    AzureCredential [Windows PS Credential]:
        A credential containing an Org Id username / password with access to this Azure subscription
        Multi Factor Authentication must be disabled for this credential

    The following have to be added with the Recovery Plan Name as a prefix, eg - TestPlan-StorSimRegKey [where TestPlan is the name of the recovery plan]
    [All these are String variables]

    'RecoveryPlanName'-AzureSubscriptionName: The name of the Azure Subscription
    'RecoveryPlanName'-StorSimRegKey: The registration key for the StorSimple manager    
    'RecoveryPlanName'-ResourceName: The name of the StorSimple resource
    'RecoveryPlanName'-DeviceName: The Device which has to be failed over
    'RecoveryPlanName'-TargetDeviceName: The Device on which the containers are to be failed over
    'RecoveryPlanName'-VolumeContainers: A comma separated string of volume containers present on the Device that need to be failed over, eg - "VolCon1,VolCon2" 
    'RecoveryPlanName'-AutomationAccountName: The name of the Automation Account in which the various runbooks are stored
    
.NOTES
    If a specified container can't be failed over then it'll be ignored
    If a volume container is part of a group (in case of shared backup policies) then the entire group will be failed over if even one of the containers from the group is not specified
#>

workflow Failover-StorSimple-Volume-Containers
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
     
    $DeviceName = Get-AutomationVariable -Name "$PlanName-DeviceName" 
    if ($DeviceName -eq $null) 
    { 
        throw "The DeviceName asset has not been created in the Automation service."  
    }
    
    $TargetDeviceName = Get-AutomationVariable -Name "$PlanName-TargetDeviceName" 
    if ($TargetDeviceName -eq $null) 
    { 
        throw "The TargetDeviceName asset has not been created in the Automation service."  
    }    
    
    $ContainerNames = Get-AutomationVariable -Name "$PlanName-VolumeContainers"
    if ($ContainerNames -eq $null) 
    { 
        throw "The VolumeContainers asset has not been created in the Automation service."  
    }
    $VolumeContainers =  $ContainerNames.Split(",").Trim() 
    
    $VMGUIDString = Get-AutomationVariable -Name "$PlanName-VMGUIDS" 
    if ($VMGUIDString -eq $null) 
    { 
        throw "The VMGUIDS asset has not been created in the Automation service."  
    }
    
    $AutomationAccountName = Get-AutomationVariable -Name "$PlanName-AutomationAccountName"
    if ($AutomationAccountName -eq $null) 
    { 
        throw "The AutomationAccountName asset has not been created in the Automation service."  
    }

    # Stops the script at first exception
    # Setting this option to suspend if Azure-Login fails
    $ErrorActionPreference = "Stop"
    
    #Connect to Azure
    Write-Output "Connecting to Azure"
    try {
        $AzureAccount = Add-AzureAccount -Credential $cred      
        $AzureSubscription = Select-AzureSubscription -SubscriptionName $SubscriptionName
        #$AzureRmAccount = Login-AzureRmAccount –Credential $cred
        if (($AzureSubscription -eq $null) -or ($AzureAccount -eq $null))
        {
            throw "Unable to connect to Azure"
        }
    }
    catch {
        throw "Unable to connect to Azure"
    }

    # Reset ErrorActionPreference if Azure-Login succeeded
    $ErrorActionPreference = "continue"
    
    # Connect to StorSimple Resource
    Write-Output "Connecting to StorSimple Resource $ResourceName"
    $StorSimpleResource = Select-AzureStorSimpleResource -ResourceName $ResourceName -RegistrationKey $RegistrationKey
    if ($StorSimpleResource -eq $null)
    {
        throw "Unable to connect to the StorSimple resource $ResourceName"
    } 
    
    $Device = Get-AzureStorSimpleDevice -DeviceName $DeviceName
    if ($Device -eq $null)
    {
        throw "Device $DeviceName does not exist"
    }
    
    $TargetDevice = Get-AzureStorSimpleDevice -DeviceName $TargetDeviceName
    if (($TargetDevice -eq $null) -or ($TargetDevice.Status -ne "Online"))
    {
        throw "Target device $TargetDeviceName does not exist or is not online"
    }    
    
    InlineScript
    {
        $DeviceName = $Using:DeviceName 
        $TargetDeviceName = $Using:TargetDeviceName 
        $VolumeContainers =  $Using:VolumeContainers 
        $RecoveryPlanContext= $Using:RecoveryPlanContext
        $SLEEPTIMEOUT = 5 # Value in seconds
        $SLEEPTIMEOUTSMALL = 1 # Value in seconds
        $CurrentTime = Get-Date
        
        # Swap in case of a failback
        if ($RecoveryPlanContext.FailoverType -eq "Failback")
        {
            $DeviceName,$TargetDeviceName = $TargetDeviceName,$DeviceName  
        }
    
        # Get all volume container groups from a Device which are eligible for a failover
        $eligibleContainers = Get-AzureStorSimpleFailoverVolumeContainers -DeviceName $DeviceName | Where-Object {$_.IsDCGroupEligibleForDR -eq $True}
        if ($eligibleContainers -eq $null)
        {
            throw "No volume containers exist on the Device that can be failed over"
        }
        
        # ContainerNamesArray - stores the ContainerNames of the volume containers for comparison
        $ContainerNamesArray = @()
        $eligibleContainers | %{$ContainerNamesArray += (,$_.DCGroup.Name)}

        # ChosenVolContainers - volume containers that are eligible to be failed over from the ones enters by the user 
        $chosenVolContainers = @()

        # Find the common containers between the ones entered by the user and the ones those are eligible for a failover
        # If a volume container belongs to a group, then all the volume containers in that group will be failed over (in case of a shared backup poilcy)
        foreach ($i in $VolumeContainers)
        {
            for ($j=0; $j -lt $ContainerNamesArray.Length; $j++)
            {
                if ($ContainerNamesArray[$j].Contains($i) -and $chosenVolContainers.Contains($eligibleContainers[$j]) -eq $false)
                {
                    $chosenVolContainers += $eligibleContainers[$j]
                }
            }
        }   
        if ($chosenVolContainers.Length -eq 0)
        {
           throw "No containers among the specified ones are eligible for failover"
        }    
        
        if (($RecoveryPlanContext.FailoverType -eq "Planned") -or ($RecoveryPlanContext.FailoverType -eq "Failback"))
        {        
            $BackupPolicies = @()
            
            Write-Output "Fetching backup policies"
            
            # The backup policies are those which were used to take the last successful backup
            foreach ($VolCon in $chosenVolContainers.DCGroup.Name)
            {
                $volumes = Get-AzureStorSimpleDeviceVolumeContainer -DeviceName $DeviceName -VolumeContainerName $VolCon | Get-AzureStorSimpleDeviceVolume -DeviceName $DeviceName
                foreach ($vol in $volumes)
                {
                   $Backups = Get-AzureStorSimpleDeviceBackup -DeviceName $DeviceName -VolumeId $vol.InstanceId | Where-Object {$_.Type -eq "CloudSnapshot"} | Sort "CreatedOn" -Descending
                   if ($Backups -eq $null)
                   {
                       throw "No backup exists for the volume"
                   }

                   # Take the first element which will represent the latest backup, since it is sorted by creation time in descending order
                   $BackupPolicyName = (@($Backups.Name))[0]
                   
                   if ($BackupPolicies.Contains($BackupPolicyName) -eq $false)
                   {
                       $BackupPolicies += $BackupPolicyName
                   }
                }
            }
            
            if ($BackupPolicies.Length -eq 0)
            {
                throw "No backup policies were found"
            }
            
            Write-Output "Backup(s) initiated"
            
            $countOfTriggeredBackups = 0
            # Take the backup
            foreach ($policy in $BackupPolicies)
            {
                $BackupPolicy = Get-AzureStorSimpleDeviceBackupPolicy -DeviceName $DeviceName  -BackupPolicyName $policy
                if ($BackupPolicy -eq $null)
                {
                    throw "Unable to fetch backup(s)"
                }     

                $backupjob = Start-AzureStorSimpleDeviceBackupJob -DeviceName $DeviceName -BackupPolicyId  $BackupPolicy.InstanceId -BackupType CloudSnapshot 
                if ($backupjob -eq $null)
                {
                    throw "Unable to take a backup"
                }   
                $countOfTriggeredBackups+=1                
            }
            
            $jobIDs = $null
            $elapsed = [System.Diagnostics.Stopwatch]::StartNew()
            while ($true)
            {
                Start-Sleep -s $SLEEPTIMEOUT
                                
                $jobIDs = @((Get-AzureStorSimpleJob -Type ManualBackup -DeviceName $DeviceName -From $CurrentTime).InstanceId)
                
                $jobIDsReady = $true
                foreach ($jobID in $jobIDs)
                {
                    if ($jobID -eq $null)
                    {
                        $jobIDsReady = $false
                        break
                    }
                }
                
                if ($jobIDsReady -ne $true)
                {
                    continue
                }
                
                if ($jobIDs.Length -eq $countOfTriggeredBackups)
                {
                    break
                }           
            }      
            
            Write-Output "Waiting for backups to finish"
            $checkForSuccess=$true
            foreach ($id in $jobIDs)
            {
                while ($true)
                {
                    $status = Get-AzureStorSimpleJob -InstanceId $id
                    Start-Sleep -s $SLEEPTIMEOUT
                    if ( $status.Status -ne "Running")
                    {
                        if ( $status.Status -ne "Completed")
                        {
                            $checkForSuccess=$false
                        }
                        break
                    }
                }
            }
            if ($checkForSuccess)
            {
                Write-Output ("Backups completed successfully")
            }
            else
            {
                throw ("Backups unsuccessful")            
            } 
        }        

        if ($RecoveryPlanContext.FailoverType -ne "Test")
        {
            Write-Output "Triggering failover of the chosen volume containers"
            $fromTime = (Get-Date) + (New-TimeSpan -Minutes -1)
            $jobID = Start-AzureStorSimpleDeviceFailoverJob -VolumecontainerGroups $chosenVolContainers -DeviceName $DeviceName -TargetDeviceName $TargetDeviceName -Force

            Start-Sleep -s $SLEEPTIMEOUT
            $jobData = Get-AzureStorSimpleJob -DeviceName $TargetDeviceName -Status 'Running' -Type 'DeviceRestore' -From $fromTime  
            
            if ($jobData -eq $null)
            {
                throw "Failover couldn't be initiated on $DeviceName"
            }
            elseIf ($jobData.Count -gt 1) {
                $jobID = $jobData[0].InstanceId
            }
            else {
                $jobID = $jobData.InstanceId
            }

            Write-Output "Failover initiated"
            Write-Output "Waiting for failover to complete"
            # Wait until the failover is complete
            $checkForSuccess=$true
            while ($true)
            {
                $status = Get-AzureStorSimpleJob -InstanceId $jobID 
                Start-Sleep -s $SLEEPTIMEOUT
                if ( $status.Status -ne "Running" )
                {
                    if ( $status.Status -ne "Completed")
                    {
                        $checkForSuccess=$false
                    }
                    break
                }
            }
            if ($checkForSuccess)
            {
                Write-Output ("Failover completed successfully")
            }
            else
            {
                throw ("Failover unsuccessful")            
            }
        }
        else
        {  
            # Clone all the volumes in the volume containers as per the latest backup                         
            if ($chosenVolContainers.DCGroup.VolumeList -eq $null)
            {
                throw "No volumes in the containers"
            }
            
            Write-Output "Triggering and waiting for clone(s) to finish"
            foreach ($vol in $chosenVolContainers.DCGroup.VolumeList)
            {   
                $volume = Get-AzureStorSimpleDeviceVolume -DeviceName $DeviceName -VolumeName $vol.DisplayName
                if ($volume -eq $null)
                {
                    throw "Volume doesn't exist on the container"
                }                
                
                $backups = $volume | Get-AzureStorSimpleDeviceBackup -DeviceName $DeviceName | Where-Object {$_.Type -eq "CloudSnapshot"} | Sort "CreatedOn" -Descending
                if ($backups -eq $null)
                {
                    throw "No backup exists for the volume"                
                }           
                     
                # This gives the latest backup                     
                $latestBackup = $backups[0]

                # Match the volume name with the volume data inside the backup 
                $snapshots = $latestBackup.Snapshots
                $snapshotToClone = $null
                foreach ($snapshot in $snapshots)
                {
                    if ($snapshot.Name -eq $volume.name)
                    {
                        $snapshotToClone = $snapshot
                        break
                    }
                } 

                Write-Output "Clone volume name: $($volume.Name)"
                $jobID = Start-AzureStorSimpleBackupCloneJob -SourceDeviceName $DeviceName -TargetDeviceName $TargetDeviceName -BackupId $latestBackup.InstanceId -Snapshot $snapshotToClone -CloneVolumeName  $volume.Name -TargetAccessControlRecords $volume.AcrList -Force
                if ($jobID -eq $null)
                {
                    throw "Clone couldn't be initiated for volume $($volume.Name)"
                }
                
                $checkForSuccess=$true
                while ($true)
                {
                    $status = Get-AzureStorSimpleJob -InstanceId $jobID
                    Start-Sleep -s $SLEEPTIMEOUT
                    if ( $status.Status -ne "Running")
                    {
                        if ( $status.Status -ne "Completed")
                        {
                            $checkForSuccess=$false                            
                        }
                        break
                    }
                }

                if ($checkForSuccess)
                {
                    Write-Output "Clone successful for volume $($volume.Name)"
                }     
                else
                {
                    throw ("Clone unsuccessful for volume $($volume.Name)")
                }
            }    
            Write-Output ("Clone(s) completed")  
        }           
    }
}