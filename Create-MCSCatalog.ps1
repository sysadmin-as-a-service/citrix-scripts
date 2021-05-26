#---------------------------------------------------------------------------
# Create MCS Catalogs on multiple clusters from one golden image
# Create a new Delivery Group and assign machines to it from each catalog
# 
# 
# 
#---------------------------------------------------------------------------

# Set variables for the target infrastructure
# ----------
Param(
    # VMM Server
    [Parameter(Mandatory=$false)]
    [string]$VMMServer = 'oncvmm01.infra.saaas.com',
    [Parameter(Mandatory=$false)]
    [System.Management.Automation.PSCredential]$SCVMMCred = (New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList "INFRA\Administrator",(Get-Content "\\XADCSF01\C$\Scripts\MCSScripts\MCSCredential.txt" | ConvertTo-SecureString -Key (get-content "\\XADCSF01\C$\Scripts\MCSScripts\AES.key"))),

    # XD Controllers
    [Parameter(Mandatory=$false)]
    [string]$adminAddress = 'xadcsf01.corp.saaas.com', #The XD Controller we're going to execute against
    [Parameter(Mandatory=$false)]
    [array]$xdControllers = ('xadcsf01.corp.saaas.com','xadcsf02.corp.saaas.com'),

    # Hypervisor and storage resources
    # These need to be configured in Studio prior to running this script
    [Parameter(Mandatory=$true)]
    [array]$storageResources = ("VC10","VC11"), # Clusters you want these VDAs on
    [Parameter(Mandatory=$false)]
    [string]$hostResource = "ONCVMM01", # Name of your hosting connection

    # Master image properties
    [Parameter(Mandatory=$true)]
    [string]$machineCatalogBaseName = "MCS Catalog - Client 01",
    [Parameter(Mandatory=$true)]
    [string]$masterImage = "XA19VDA01", # Name of Master Image VM 
    [Parameter(Mandatory=$false)]
    [string]$snapshot = $null, # Name of your snapshot. If you want to create a new snapshot, do $snapshot = $null

    # Details on the machines you want built/updated
    [Parameter(Mandatory=$true)]
    [string]$machineNamingConvention = "XA19VDA##", # the #'s are replaced by two numbers
    [Parameter(Mandatory=$false)]
    [int]$vmCPU = 6,
    [Parameter(Mandatory=$false)]
    [int]$vmMemory = 14336,

    #AD domain details
    [Parameter(Mandatory=$false)]
    [string]$adDomain = "$env:userDNSDomain",
    [Parameter(Mandatory=$false)]
    [string]$adOU = "OU=MCS Nodes,OU=Citrix Servers,OU=Servers,DC=corp,DC=saaas,DC=com"
)
#EndParamBlock

# Email Report Variables
$emailTo = "sysadmin@saaas.com"
$reportFilter = $machineCatalogBaseName

# ----------

# Load the Citrix PowerShell modules
Write-Verbose "Loading Citrix XenDesktop modules."
if(!(Get-PSSnapin Citrix* -ea SilentlyContinue)){
    Add-PSSnapin Citrix*
}
if(!(Get-Module VirtualMachineManager -ea SilentlyContinue)){
    Import-Module virtualmachinemanager
}


# Set up the connection to the SCVMM server
Get-SCVMMServer -ComputerName $VMMServer -Credential $SCVMMCred | Out-Null

# Find where your golden image is sitting at the moment, and reorder your storageResources array
$masterImageCurrentCluster = (Get-SCVirtualMachine $masterImage).VMHost.HostCluster -replace "\.infra\.saaas\.com"
$sr = @{}
$storageResources | % { if($_ -eq $masterImageCurrentCluster){ $sr.Add($_,1) }else{ $sr.Add($_,0) } }
$storageResources = $sr.GetEnumerator() | Sort -Property Value -Descending

foreach($storageResource in $storageResources.Name){

    Write-Host "`-------------------------------------------------" -fore yellow
    Write-Host "`nAdding Machine Catalog for $($storageResource)`n" -fore yellow
    Write-Host "`-------------------------------------------------" -fore yellow

    # Get information from the hosting environment via the XD Controller
    # Get the storage resource
    Write-Verbose "Gathering storage and hypervisor connections from the XenDesktop infrastructure."
    $hostingUnit = Get-ChildItem -AdminAddress $adminAddress "XDHyp:\HostingUnits" | Where-Object { $_.PSChildName -like $storageResource } | Select-Object PSChildName, PsPath
    $hostConnection = Get-ChildItem -AdminAddress $adminAddress "XDHyp:\Connections" | Where-Object { $_.PSChildName -like $hostResource }
    $brokerHypConnection = Get-BrokerHypervisorConnection -AdminAddress $adminAddress -HypHypervisorConnectionUid $hostConnection.HypervisorConnectionUid
    $brokerServiceGroup= Get-ConfigServiceGroup -ServiceType 'Broker' -MaxRecordCount 2147483647 -AdminAddress $adminAddress


    # Machine Catalog name e.g. MCS Catalog - Admin Desktop - VC08
    $machineCatalogName = "$($machineCatalogBaseName) - $($storageResource)"
    
    # Check whether the VM is on the current cluster
    $masterImageCurrentCluster = (Get-SCVirtualMachine $masterImage -VMMServer $VMMServer).VMHost.HostCluster -replace "\.infra\.saaas\.com"
    if($masterImageCurrentCluster -ne $storageResource){
        # Need to move the VM to the next cluster
        Write-Host "Master image $($masterImage) is currently on $($masterImageCurrentCluster). Moving to $($storageResource)." -ForegroundColor Yellow
        # Need to find best storage path and virtual host
        try{
            Get-SCVMHostCluster -Name "$($storageResource).infra.saaas.com" | Read-SCVMHostCluster | Out-Null
            $ratings = Get-SCVMHost -VMMServer $VMMServer | ? {$_.HostCluster.Name -eq "$($storageResource).infra.saaas.com"}  | select Name,HostCluster,@{n="Rating";e={(Get-SCVMHostRating -VM $masterImage -VMHost $_).Rating}},@{n="PreferredStorage";e={(Get-SCVMHostRating -VM $masterImage -VMHost $_).PreferredStorage}},OperatingSystem
        }catch{
            Write-Host "Error getting Host Ratings. Couldn't determine the best location for $($masterImage). Cancelling move..." -fore red
            Continue
        }
        
        $destHost = $ratings | Sort Rating -Descending | Select -First 1
        $destPath = $destHost.PreferredStorage
        Write-Host "Found best destination host $($destHost.Name) and $($destPath)" -fore Yellow
        
        if($destHost.OperatingSystem.Name -match "2016"){
        Write-Host "Moving server to a 2016 host, configuring to use SET switch" -fore Yellow
            $destNetwork = "Guest-VM"
            $destSwitch = "SETswitch"

        }elseif($destHost.OperatingSystem.Name -match "2012"){
            Write-Host "Moving server to a 2012 host, configuring to use ConvergedNetSwitch" -fore Yellow
            $destNetwork = "ConvergedNetSwitch"
            $destSwitch = "ConvergedNetSwitch"
            
        }
        # Changing network adapter
        $jobGroup = ([guid]::NewGUID()).Guid
        $vmNetwork = Get-SCVMNetwork -Name $destNetwork

        $virtualNetworkAdapter = Get-SCVirtualNetworkAdapter -VM $masterImage
        Set-SCVirtualNetworkAdapter -VirtualNetworkAdapter $virtualNetworkAdapter -VirtualNetwork $destSwitch -VMNetwork $vmNetwork -JobGroup $jobGroup | Out-Null 
    
        Move-SCVirtualMachine -VM $masterImage -BlockLiveMigrationIfHostBusy -UseDiffDiskOptimization -UseLAN -Path $destPath -VMHost $destHost.Name -RunAsynchronously -JobGroup $jobGroup | Out-Null
        Start-Sleep 5
        $i = 0
        do { $job = Get-SCVirtualMachine -Name $masterImage ; Start-Sleep 5; $i++ }until(($job.MostRecentTask -like "*migrate*") -or ($i -gt 59))
        $jobID = $job.MostRecentTaskID
        # Progress bar
        do{
            $job = Get-SCJob -ID $jobID
            Write-Progress -Activity "Moving $($masterImage) to $($destHost.Name)" -Status "$($job.Status) - $($job.Progress)" -PercentComplete ($job.Progress -replace "%")
            Start-Sleep 1
        }until($job.Status -match "Completed" -or $job.Status -eq "Failed" -or $job.Status -match "Succeed")
        if($job.Status -eq "Failed"){
            Write-Host "Migration of $($masterImage) to $($destHost.Name) failed!" -ForegroundColor Red
            Continue
        }
        #Refresh-VM $masterImage | Out-Null
        $masterImageCurrentCluster = (Get-SCVirtualMachine $masterImage -VMMServer $VMMServer).VMHost.HostCluster -replace "\.infra\.saaas\.com"
        Write-Host "$($masterImage) is now on $($masterImageCurrentCluster)." -ForegroundColor Yellow

    }else{
        Write-Host "$($masterImage) is on $($masterImageCurrentCluster) already, proceeding..." -fore Yellow
    }

    # Create the Machine Catalog
    if((Test-BrokerCatalogNameAvailable -Name $machineCatalogName).Available -eq $true){
        $catalog = New-BrokerCatalog  -AdminAddress $adminAddress -AllocationType "Random" -IsRemotePC $False -MinimumFunctionalLevel "L7_6" -Name $machineCatalogName -PersistUserChanges "Discard" -ProvisioningType "MCS" -Scope @() -SessionSupport "MultiSession"
    }else{
        Write-Host "Machine Catalog name already in use! Please choose a different name, or remove this Machine Catalog if it is from a previous failed attempt by using Get-BrokerCatalogName $machineCatalogName | Remove-BrokerCatalog" -fore red
        pause
        Continue
    }

    # Create the machine account identity pool
    if((Test-AcctIdentityPoolNameAvailable -IdentityPoolName $machineCatalogName).Available -eq $true){
        $adPool = New-AcctIdentityPool  -AdminAddress $adminAddress -AllowUnicode -Domain $adDomain -IdentityPoolName $machineCatalogName -NamingScheme $machineNamingConvention -NamingSchemeType "Numeric" -OU $adOU -Scope @()
    }else{
        Write-Host "Account Identity name ($machineCatalogName)already in use, possibly from a previous failed attempt. Remove this AcctIdentityPool using Get-AcctIdentityPool $machineCatalogName | Remove-AcctIdentityPool" -fore red
        pause
        Continue
    }
    
    # Create the provisioning scheme and wait for completion
    $VM = $null
    $getVMTries = 0
    do{
	$getVMTries++	
	Write-Host "Searching for the VM through the XD Hypervisor connection - attempt $($getVMTries)" -fore DarkCyan
	
	# sometimes xdhyp: seems to be case sensitive??
	$VM = Get-Item -AdminAddress $adminAddress "XDHyp:\HostingUnits\$($storageResource)\$($masterImage.ToUpper()).VM" -ErrorAction SilentlyContinue
	if($VM -eq $null -and $getVMTries -le 2){
		Write-Host "Couldn't find the VM through the XD Hypervisor connection! Will try again in 60s..." -fore DarkCyan
		Start-Sleep -Seconds 60
	}
    }until($VM -ne $null -or $getVMTries -gt 2) 
    if($VM -eq $null){
	Write-Host "Couldn't find $($masterImage) on $($storageResource) through the hypervisor connection!" -fore Yellow
	Write-Host "Cancelling..." -fore Red
	Continue
    }	
        
	# Shut down the VM, so it doesn't update the image in a "crashed" state
	Write-Host "Checking if $($masterImage) is ready to be shut down" -fore DarkCyan
	$repairTries = 0
	do{
		$masterImageStatus = (Get-SCVirtualMachine -Name $masterImage).Status
		if($masterImageStatus -notmatch "Running|Stopped|PowerOff"){
			Write-Host "$($masterImage) is in the state $($masterImageStatus). Attempting a repair..." -fore DarkCyan
			Repair-SCVirtualMachine -VM $masterImage -Force -Dismiss | Out-Null
			$masterImageStatus = (Get-SCVirtualMachine -Name $masterImage).Status
			$repairTries++
		}
	}until($masterImageStatus -match "Running|Stopped|PowerOff" -or $repairTries -gt 2)
	if($masterImageStatus -notmatch "Running|Stopped|PowerOff"){
		Write-Host "$($masterImage) is not in a good state ($($masterImageStatus))! Cancelling..." -fore Red
		Continue
	}

        Write-Host "Restarting $($masterImage) and taking snapshot" -fore DarkCyan
	$masterImageStatus = (Get-SCVirtualMachine -Name $masterImage).Status
	if($masterImageStatus -ne "PowerOff"){
		$stopTries = 0	
		do{
			$stopJob = $null
			Stop-SCVirtualMachine -VM $masterImage -Shutdown -JobVariable StopJob -ErrorAction SilentlyContinue | Out-Null
		        if($stopJob.Status -eq "Failed"){
	        		Write-Host "Failed to stop VM, refreshing..." -ForegroundColor Red

			        Repair-SCVirtualMachine -VM $masterImage -Force -Dismiss | Out-Null
				$stopTries++
			}
	        }until($stopJob.Status -ne "Failed" -or $stopTries -gt 2 -or $masterImageStatus -eq "PowerOff")
		if($stopJob.Status -eq "Failed"){
			Write-Host "Failed to stop VM after refreshing twice, must be a critical error!" -ForegroundColor Red
			Write-Host "Cancelling update of $($machineCatalogName)" -ForegroundColor Red
			Continue
		}
		Start-Sleep 15
	}
	
	# Machine is now stopped	    
	Write-Host "$($masterImage) is now stopped" -fore DarkCyan

	Write-Host "Checking if $($masterImage) is ready to be snapshotted" -fore DarkCyan
	$repairTries = 0
	do{
		$masterImageStatus = (Get-SCVirtualMachine -Name $masterImage).Status
		if($masterImageStatus -notmatch "Running|Stopped|PowerOff"){
			Write-Host "$($masterImage) is in the state $($masterImageStatus). Attempting a repair..." -fore DarkCyan
			Repair-SCVirtualMachine -VM $masterImage -Force -Dismiss | Out-Null
			$masterImageStatus = (Get-SCVirtualMachine -Name $masterImage).Status
			$repairTries++
		}
	}until($masterImageStatus -match "Running|Stopped|PowerOff" -or $repairTries -gt 2)
	if($masterImageStatus -notmatch "Running|Stopped|PowerOff"){
		Write-Host "$($masterImage) is not in a good state ($($masterImageStatus))! Cancelling..." -fore Red
		Continue
	}

	    $TargetImage = $null		
	    $TargetImage = New-HypVMSnapshot -LiteralPath $VM.FullPath -SnapshotName "MCS_$($machineCatalogName)"
	    # Restart the VM
	    Start-SCVirtualMachine -VM $masterImage | Out-Null
    #}

    if(!($TargetImage)){
        Write-Host "Snapshot variable is $($snapshot)"
        Write-Host "Snapshot is equal to null? $($snapshot -eq $null)"
        Write-Host "Snapshot either failed or snapshot variable didn't match an existing snapshot on master image $($masterImage)." -ForegroundColor Red
        #$error[0]
        #pause
        Continue
    }

    Write-Host "Adding a new provisioning scheme" -fore Yellow
    if((Test-ProvSchemeNameAvailable  -AdminAddress $adminAddress -ProvisioningSchemeName @($machineCatalogName)).Available -eq $true){
        #$provSchemeTaskID = New-ProvScheme  -AdminAddress $adminAddress -CleanOnBoot -HostingUnitName $storageResource -IdentityPoolUID $adPool.IdentityPoolUid -MasterImageVM $TargetImage -ProvisioningSchemeName $machineCatalogName -RunAsynchronously -Scope @() -VMCpuCount $vmCPU -VMMemoryMB $vmMemory
        $provSchemeTaskID = New-ProvScheme -HostingUnitName $hostingUnit.PSChildName -IdentityPoolName $adPool.IdentityPoolName -MasterImageVM $TargetImage -ProvisioningSchemeName $machineCatalogName -AdminAddress $adminAddress -CleanOnBoot -RunAsynchronously -VMCpuCount $vmCPU -VMMemoryMB $vmMemory -UseWriteBackCache -WriteBackCacheDiskSize 100 -WriteBackCacheMemorySize 2048 
    }else{
        Write-Host "Provisioning Scheme name already in use! Please choose a different name, or remove this Provisioning Scheme if it is from a previous failed attempt by using Get-ProvScheme $machineCatalogName | Remove-ProvScheme" -red
        pause
        Continue
    }
     # Progress bar
        do{
            $completion = $job.TaskExpectedCompletion - (Get-Date)
            $job = Get-ProvTask -TaskID $provSchemeTaskID -AdminAddress $adminAddress
            Write-Progress -Activity "Creating provisioning scheme for $($machineCatalogName) - $([math]::Round($completion.TotalMinutes,0)) minutes remaining" -Status "$($job.TaskState) - $([int]$job.TaskProgress)%" -PercentComplete ([int]$job.TaskProgress)
            Start-Sleep 5
        }until($job.WorkflowStatus -eq "Completed")
    # Check if it completed successfully
    if($job.TaskState -ne "Finished"){
        Write-Host "The machine update task failed with error: $($job.TaskState). Proceeding to next cluster..." -fore Red
        Get-SCVMCheckpoint -VM $masterImage -MostRecent | Remove-SCVMCheckpoint | Out-Null
        Continue
    }elseif($job.Active -eq $false){
        Write-Host "Finished updating the machine catalog on $($storageResource)" -fore Green
        Get-SCVMCheckpoint -VM $masterImage -MostRecent | ? {$_.Name -like "MCS*"} |  Remove-SCVMCheckpoint | Out-Null
    }
    # Assign this provisioning scheme to our broker catalog
    Set-BrokerCatalog -Name $catalog.Name -ProvisioningSchemeId $job.ProvisioningSchemeUid
}


# Create the Delivery Group and assign machines manually

# This will email a report to you upon completion.
cd "C:\Scripts\MCSScripts"
.\MCS-Report.ps1 `
-filter $reportFilter `
-emailTo $emailTo `
-emailSubject "$($machineCatalogBaseName) Creation Task"
