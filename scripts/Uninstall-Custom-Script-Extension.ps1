<#
.DESCRIPTION
    This runbook uninstalls the Custom Script Extension from the Azure VMs (brought up after a failover)
    This is required so that after a failover -> failback -> failover, the Custom Script Extension can trigger the iSCSI script
     
.ASSETS (The following need to be stored as Automation Assets) 
    [You can choose to encrypt these assets] 
    
    AzureCredential [Windows PS Credential]: A credential containing an Org Id username / password with access to this Azure subscription
    Multi Factor Authentication must be disabled for this credential
    
    The following have to be added with the Recovery Plan Name as a prefix, eg - TestPlan-StorSimRegKey [where TestPlan is the name of the recovery plan]
    [All these are String variables]
    
    'RecoveryPlanName'-AzureSubscriptionName: The name of the Azure Subscription
    'RecoveryPlanName'-VMGUIDS: 
        	Upon protecting a VM, ASR assigns every VM a unique ID which gives the details of the failed over VM. 
        	Copy it from the Protected Item -> Protection Groups -> Machines -> Properties in the Recovery Services tab.
        	In case of multiple VMs then add them as a comma separated string
#>

workflow Uninstall-Custom-Script-Extension
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
    
    $VMGUIDString = Get-AutomationVariable -Name "$PlanName-VMGUIDS" 
    if ($VMGUIDString -eq $null) 
    { 
        throw "The VMGUIDs asset has not been created in the Automation service."  
    }
    $VMGUIDs =  $VMGUIDString.Split(",").Trim()

    # Stops the script at first exception
    # Setting this option to suspend if Azure-Login fails
    $ErrorActionPreference = "Stop"
    
    #Connect to Azure
    Write-Output "Connecting to Azure"
    try {
        $AzureAccount = Login-AzureRmAccount -Credential $cred
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

    # Reset ErrorActionPreference if Azure-Login succeeded
    $ErrorActionPreference = "continue"

    foreach  ($VMGUID in $VMGUIDs)
    { 
        #Fetch VM Details 
        $VMContext = $RecoveryPlanContext.VmMap.$VMGUID    
        if ($VMContext -eq $null)
        {
            throw "The VM corresponding to the VMGUID - $VMGUID is not included in the Recovery Plan"
        } 

        $VMRoleName =  $VMContext.RoleName 
        if ($VMRoleName -eq $null)
        {
            throw "Role name is null for VMGUID - $VMGUID"
        }

        $VMServiceName = $VMContext.CloudServiceName       
        if ($VMServiceName -eq $null)
        {
            #throw "Service name is null for VMGUID - $VMGUID"
            $VMServiceName = (Get-AzureRmVM | where Name -eq $VMRoleName).ResourceGroupName    
        }
         
        InLineScript 
        {
            $VMRoleName = $Using:VMRoleName
            $VMServiceName = $Using:VMServiceName            
            
            $AzureVM = Get-AzureRmVM -Name $VMRoleName -ResourceGroupName $VMServiceName              
            if ($AzureVM -eq $null)
            {
                throw "Unable to fetch details of Azure VM - $VMRoleName"
            }
            
            Write-Output "Uninstalling custom script extension on $VMRoleName" 
            try
            { 
                #$result = Set-AzureVMCustomScriptExtension -Uninstall -ReferenceName CustomScriptExtension -VM $AzureVM | Update-AzureVM
                $result = Remove-AzureRmVMCustomScriptExtension -ResourceGroupName $VMServiceName -VMName $VMRoleName -Name "CustomScriptExtension" -Force
            }  
              
            catch
            {
                throw "Unable to uninstall custom script extension - $VMRoleName"
            }                          
        } 
    }
}
