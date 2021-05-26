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
    [string]$VMMServer = 'oncvmm02.infra.saaas.com',
    [Parameter(Mandatory=$false)]
    [System.Management.Automation.PSCredential]$SCVMMCred = (Import-Clixml C:\Scripts\MCSScripts\Cred.xml),
    [Parameter(Mandatory=$false)]
    [string]$vhostFQDN = ".infra.saaas.com",

    # XD Controllers
    [Parameter(Mandatory=$true)]
    [string]$adminAddress = 'xadcsf01.corp.saaas.com', #The XD Controller we're going to execute against
    [Parameter(Mandatory=$true)]
    [array]$xdControllers = ('xadcsf01.corp.saaas.com','xadcsf02.corp.saaas.com'),

    # Hypervisor and storage resources
    # These need to be configured in Studio prior to running this script
    [Parameter(Mandatory=$true)]
    [array]$storageResources = ("VC08","VC10","VC11"), # Clusters you want these VDAs on
    [Parameter(Mandatory=$true)]
    [string]$hostResource = "ONCVMM01", # Name of your hosting connection

    # Master image properties
    [Parameter(Mandatory=$true)]
    [string]$machineCatalogBaseName,
    [Parameter(Mandatory=$true)]
    [string]$masterImage, # Name of Master Image VM 
    [Parameter(Mandatory=$false)]
    [string]$snapshot = $null, # Name of your snapshot. If you want to create a new snapshot, do $snapshot = $null

    # Details on the machines you want built/updated
    [Parameter(Mandatory=$false)]
    [string]$machineNamingConvention, # the #'s are replaced by two numbers
    [Parameter(Mandatory=$false)]
    [int]$vmCPU = 4,
    [Parameter(Mandatory=$false)]
    [int]$vmMemory = 8192,

    # Other options
    [Parameter(Mandatory=$false)]
    [string]$mode = "fix",
    [Parameter(Mandatory=$false)]
    [string]$emailTo = "CitrixTeam@saaas.com",
    [Parameter(Mandatory=$false)]
    [string]$emailFrom = "Citrix Reporting <xadcsf01@corp.saaas.com>",
    [Parameter(Mandatory=$false)]
    [string]$logFile = "\\XADCSF01\C$\inetpub\wwwroot\Director\Reports\$($machineCatalogBaseName)-Detailed.txt"
)
#EndParamBlock

function Write-Log {
param(
	[string]$text,
	[string]$colour,
	[string]$logFilePath,
	[bool]$append = $true
)
$text = "$(Get-Date -Format g) - $($text)"

if($colour -eq "" -or $colour -eq $null){
    $colour = "White"
}
if($append){
    $text | Out-File -FilePath $logFilePath -Append 
}else{
	$text | Out-File -FilePath $logFilePath
}
    Write-Host $text -fore $colour
}



#Log file location
Write-Log -text "`n$(Get-Date -Format G) - Starting update of $($machineCatalogBaseName) - $($storageResources -join ", ")" -logFilePath $logFile -colour DarkCyan -append $false

# Load the Citrix PowerShell modules
Write-Verbose "Loading Citrix XenDesktop modules."
if(!(Get-PSSnapin Citrix* -ea SilentlyContinue)){
    Add-PSSnapin Citrix*
}
if(!(Get-Module VirtualMachineManager -ea SilentlyContinue)){
    Import-Module virtualmachinemanager
}

# Set up the connection to the SCVMM server
$vmmConnAttempts = 0
do{
    $vmmConn = Get-SCVMMServer -ComputerName $VMMServer -Credential $SCVMMCred
    if($vmmConn -eq $null){
        Write-Log -text "It seems the connection to VMM has failed, pausing a bit and then retrying..." -logFilePath $logfile -colour Red
        Start-Sleep -Seconds 60
        $vmmConnAttempts++
    }
}until($vmmConn -ne $null -or $vmmConnAttempts -gt 2)

if($vmmConn -eq $null){
    Write-Log -text "Couldn't connect to VMM! Emailing report and cancelling run." -logFilePath $logFile -colour Red
    #Send-MailMessage -To $emailTo -From $emailFrom -Subject "$($reportFilter) Update Task" -Body "The Update Task for $($reportFilter) failed, due to a VMM connection error" -SmtpServer mx-gslb.saaas.com
    Exit
}


# Start!

switch($mode){
	"fix" {
		$fix = $true
		Write-Log -text "Running in FIX Mode! This will only update catalogs that haven't been updated in the last 24 hours!" -logFilePath $logfile -colour DarkCyan
	}
	"normal" {
		$fix = $false
		Write-Log -text "Running in NORMAL Mode! This will update all catalogs regardless of last update time" -logFilePath $logfile -colour DarkCyan
	}
}

#pause

# Only include catalogs in your zone - the Delivery Controllers in one zone probably don't have
#   access to the virtual hosts/VMM servers in the secondary zones, and we want to avoid 
#   unnecessary errors!
$zones = Get-ConfigZone
# Remove anything after a "." in the name of the adminAddress, in case FQDN has been used e.g. ctxcontroller.ctx.corp > ctxcontroller
$currentZone = $zones | ? {($adminAddress -replace "\..*") -in $_.ControllerNames}
if($currentZone){  
    Write-Log -text "Found current zone for $($adminAddress) - $($currentZone.Description)" -logFilePath $logFile -colour DarkCyan
    # Get the storage resources in these connections
    $localStorageResources = gci XDHyp:\HostingUnits | ? {$_.HypervisorConnection.ZoneUID -eq $currentZone.Uid} 
    Write-Log -text "Local Storage Resources: $($localStorageResources.PSChildName -join ", ")" -logFilePath $logFile -colour DarkCyan
    # Filter our list to just the local storage resources
    $storageResources = $storageResources | ? {$_ -in $localStorageResources.PSChildName}
    Write-Log -text "Filtered Storage Resources list: $($storageResources -join ", ")" -logFilePath $logFile -colour DarkCyan

}else{
    Write-Log -text "Could not find a current zone for controller $($adminAddress)!" -logFilePath $logFile -colour Red
    Exit
}



Write-Log -text "About to update catalog $($machineCatalogBaseName) on $($storageResources -join ", ")" -logFilePath $logfile -colour DarkCyan
Start-Sleep -Seconds 5

# Find where your golden image is sitting at the moment, and reorder your storageResources array
$masterImageCurrentCluster = (Get-SCVirtualMachine $masterImage).VMHost.HostCluster -replace $vhostFQDN
$sr = @{}
$storageResources | % { if($_ -eq $masterImageCurrentCluster){ $sr.Add($_,1) }else{ $sr.Add($_,0) } }
$storageResources = $sr.GetEnumerator() | Sort -Property Value -Descending

foreach($storageResource in $storageResources.Name){

    Write-Log -text "`-------------------------------------------------" -logFilePath $logfile -colour Yellow
    Write-Log -text "`nUpdating Machine Catalog for $($storageResource)`n" -logFilePath $logfile -colour Yellow
    Write-Log -text "`-------------------------------------------------" -logFilePath $logfile -colour Yellow

    # Get information from the hosting environment via the XD Controller
    # Get the storage resource
    Write-Verbose "Gathering storage and hypervisor connections from the XenDesktop infrastructure."
    $hostingUnit = Get-ChildItem -AdminAddress $adminAddress "XDHyp:\HostingUnits" | Where-Object { $_.PSChildName -like $storageResource } | Select-Object PSChildName, PsPath
    $hostConnection = Get-ChildItem -AdminAddress $adminAddress "XDHyp:\Connections" | Where-Object { $_.PSChildName -like $hostResource }
    $brokerHypConnection = Get-BrokerHypervisorConnection -AdminAddress $adminAddress -HypHypervisorConnectionUid $hostConnection.HypervisorConnectionUid
    $brokerServiceGroup= Get-ConfigServiceGroup -ServiceType 'Broker' -MaxRecordCount 2147483647 -AdminAddress $adminAddress

    
    # Machine Catalog name e.g. MCS Catalog - Admin Desktop - VC08
    $machineCatalogName = "$($machineCatalogBaseName) - $($storageResource)"

    # If using "Fix" mode, just update the catalogs that haven't been updated in the last 24 hours. 
    if($fix){
        if((Get-ProvScheme $machineCatalogName).MasterImageVMDate -gt (Get-Date).AddHours(-24)){
            Write-Log -text "$($machineCatalogName) was updated within the last 24 hours - skipping..." -logFilePath $logfile -colour DarkCyan
            Continue
        }
    }
    
    # Check whether the VM is on the current cluster
    $masterImageCurrentCluster = (Get-SCVirtualMachine $masterImage -VMMServer $VMMServer).VMHost.HostCluster -replace $vhostFQDN
    if($masterImageCurrentCluster -ne $storageResource){
        # Need to move the VM to the next cluster
        Write-Log -text "Master image $($masterImage) is currently on $($masterImageCurrentCluster). Moving to $($storageResource)." -logFilePath $logfile -colour DarkCyan
        # Need to find best storage path and virtual host
        try{
            Get-SCVMHostCluster -Name "$($storageResource)$($vhostFQDN)" | Read-SCVMHostCluster | Out-Null
            $ratings = Get-SCVMHost -VMMServer $VMMServer | ? {$_.HostCluster.Name -eq "$($storageResource)$($vhostFQDN)"}  | select Name,HostCluster,@{n="Rating";e={(Get-SCVMHostRating -VM $masterImage -VMHost $_).Rating}},@{n="PreferredStorage";e={(Get-SCVMHostRating -VM $masterImage -VMHost $_).PreferredStorage}},OperatingSystem
        }catch{
            Write-Log -text "Error getting Host Ratings. Couldn't determine the best location for $($masterImage). Cancelling move..." -logFilePath $logfile -colour red
            Continue
        }
       
        $destHost = $ratings | Sort Rating -Descending | Select -First 1

		#Find best CSV on the cluster that isn't Volume1
        $csvs = Get-SCStorageVolume | ? {$_.FileSystemType -eq "CSVFS_NTFS" -and $_.VMHost.HostCluster.ClusterName -eq $storageResource} | Sort -Unique | select `
        Name, `
        VolumeLabel, `
        @{n="Size";e={[math]::Round($_.Size/1GB,0)}}, `
        @{n="Free";e={[math]::Round($_.FreeSpace/1GB,0)}}, `
        @{n="PctFree";e={ [math]::Round(($_.FreeSpace/$_.Size)*100,0) }}

        $bestVol = ($csvs | ? {$_.Name -notmatch "Volume1$"} | Sort Free -Descending | Select -First 1)
        Write-Log -text "Best volume is $($bestVol.Name), $($bestVol.Free)GB, $($bestVol.PctFree)% free on volume." -logFilePath $logfile -colour DarkCyan
        $destPath = $bestVol.Name
		
    	Write-Log -text "Found best destination host $($destHost.Name) and $($destPath)" -logFilePath $logfile -colour DarkCyan
        #     if($destHost.OperatingSystem.Name -match "2016"){
        #     Write-Host "Moving server to a 2016 host, configuring to use SET switch" -fore Yellow
        #     $destNetwork = "Guest-VM"
        #     $destSwitch = "SETswitch"

        # }elseif($destHost.OperatingSystem.Name -match "2012"){
        #     Write-Host "Moving server to a 2012 host, configuring to use ConvergedNetSwitch" -fore Yellow
        #     $destNetwork = "ConvergedNetSwitch"
        #     $destSwitch = "ConvergedNetSwitch"
            
        # }
        # # Changing network adapter
        # $jobGroup = ([guid]::NewGUID()).Guid
        # $vmNetwork = Get-SCVMNetwork -Name $destNetwork

        # $virtualNetworkAdapter = Get-SCVirtualNetworkAdapter -VM $masterImage
        # Set-SCVirtualNetworkAdapter -VirtualNetworkAdapter $virtualNetworkAdapter -VirtualNetwork $destSwitch -VMNetwork $vmNetwork -JobGroup $jobGroup | Out-Null 
              
        # $vmNetwork = Get-SCVMNetwork -Name $destNetwork
        
	$jobGroup = ([guid]::NewGUID()).Guid

	Write-Log -text "Checking if $($masterImage) is ready to be migrated" -logFilePath $logfile -colour DarkCyan
	$repairTries = 0
	do{
		$masterImageStatus = (Get-SCVirtualMachine -Name $masterImage).Status
		if($masterImageStatus -notmatch "Running|Stopped|PowerOff"){
			Write-Log -text "$($masterImage) is in the state $($masterImageStatus). Attempting a repair..." -logFilePath $logfile -colour DarkCyan
			Repair-SCVirtualMachine -VM $masterImage -Force -Dismiss | Out-Null
			$masterImageStatus = (Get-SCVirtualMachine -Name $masterImage).Status
			$repairTries++
		}
	}until($masterImageStatus -match "Running|Stopped|PowerOff" -or $repairTries -gt 2)
	if($masterImageStatus -notmatch "Running|Stopped|PowerOff"){
		Write-Log -text "$($masterImage) is not in a good state ($($masterImageStatus))! Cancelling..." -logFilePath $logfile -colour Red
		Continue
	}

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
            Write-Log -text "Migration of $($masterImage) to $($destHost.Name) failed!" -logFilePath $logfile -colour Red
            Continue
        }
            Read-SCVirtualMachine -VM $masterImage -Force | Out-Null
        $masterImageCurrentCluster = (Get-SCVirtualMachine $masterImage -VMMServer $VMMServer).VMHost.HostCluster -replace $vhostFQDN
        Write-Log -text "$($masterImage) is now on $($masterImageCurrentCluster)." -logFilePath $logfile -colour DarkCyan

    }else{
        Write-Log -text "$($masterImage) is on $($masterImageCurrentCluster) already, proceeding..." -logFilePath $logfile -colour DarkCyan
    }

    # Create the provisioning scheme and wait for completion
    $VM = $null
    $getVMTries = 0
    do{
		$getVMTries++	
		Write-Log -text "Searching for the VM through the XD Hypervisor connection - attempt $($getVMTries)" -logFilePath $logfile -colour DarkCyan
		
		#sometimes xdhyp: seems to be case sensitive. Try upper and lower and nothing.


		try{
			$VM = Get-Item -AdminAddress $adminAddress "XDHyp:\HostingUnits\$($storageResource)\$($masterImage).vm" -ErrorAction Stop
		}catch{
			try{
				$VM = Get-Item -AdminAddress $adminAddress "XDHyp:\HostingUnits\$($storageResource)\$($masterImage.ToUpper()).VM" -ErrorAction Stop
			}catch{
				try{
					$VM = Get-Item -AdminAddress $adminAddress "XDHyp:\HostingUnits\$($storageResource)\$($masterImage.ToLower()).vm"
				}catch{
					#do nada
				}
			}

		}   
		if($VM -eq $null -and $getVMTries -le 2){
			Write-Log -text "Couldn't find the VM through the XD Hypervisor connection! Will try again in 60s..." -logFilePath $logfile -colour DarkCyan
			Start-Sleep -Seconds 60
		}     

    }until($VM -ne $null -or $getVMTries -gt 2) 
    if($VM -eq $null){
	Write-Log -text "Couldn't find $($masterImage) on $($storageResource) through the hypervisor connection!" -logFilePath $logfile -colour Yellow
	Write-Log -text "Cancelling..." -logFilePath $logfile -colour Red
	Continue
    }	
        
	# Shut down the VM, so it doesn't update the image in a "crashed" state
	Write-Log -text "Checking if $($masterImage) is ready to be shut down" -logFilePath $logfile -colour DarkCyan
	$repairTries = 0
	do{
		$masterImageStatus = (Get-SCVirtualMachine -Name $masterImage).Status
		if($masterImageStatus -notmatch "Running|Stopped|PowerOff"){
			Write-Log -text "$($masterImage) is in the state $($masterImageStatus). Attempting a repair..." -logFilePath $logfile -colour DarkCyan
			Repair-SCVirtualMachine -VM $masterImage -Force -Dismiss | Out-Null
			$masterImageStatus = (Get-SCVirtualMachine -Name $masterImage).Status
			$repairTries++
		}
	}until($masterImageStatus -match "Running|Stopped|PowerOff" -or $repairTries -gt 2)
	if($masterImageStatus -notmatch "Running|Stopped|PowerOff"){
		Write-Log -text "$($masterImage) is not in a good state ($($masterImageStatus))! Cancelling..." -logFilePath $logfile -colour Red
		Continue
	}

    Write-Log -text "Restarting $($masterImage) and taking snapshot" -logFilePath $logfile -colour DarkCyan
	$masterImageStatus = (Get-SCVirtualMachine -Name $masterImage).Status
	if($masterImageStatus -ne "PowerOff"){
		$stopTries = 0	
		do{
			$stopJob = $null
			Stop-SCVirtualMachine -VM $masterImage -Shutdown -JobVariable StopJob -ErrorAction SilentlyContinue | Out-Null
		        if($stopJob.Status -eq "Failed"){
	        		Write-Log -text "Failed to stop VM, pausing for 10 minutes and refreshing... this is most often due to an current backup or replication job." -logFilePath $logFile -Color Red
				Start-Sleep -Seconds 600
			        Repair-SCVirtualMachine -VM $masterImage -Force -Dismiss | Out-Null
				$stopTries++
			}
	        }until($stopJob.Status -ne "Failed" -or $stopTries -gt 2 -or $masterImageStatus -eq "PowerOff")
		if($stopJob.Status -eq "Failed"){
			Write-Log -text "Failed to stop VM after refreshing twice, must be a critical error!" -logFilePath $logfile -colour Red
			Write-Log -text "Cancelling update of $($machineCatalogName)" -logFilePath $logfile -colour Red
			Continue
		}
		Start-Sleep 15
	}
	
	# Machine is now stopped	    
	Write-Log -text "$($masterImage) is now stopped" -logFilePath $logfile -colour DarkCyan

	Write-Log -text "Checking if $($masterImage) is ready to be snapshotted" -logFilePath $logfile -colour DarkCyan
	$repairTries = 0
	do{
		$masterImageStatus = (Get-SCVirtualMachine -Name $masterImage).Status
		if($masterImageStatus -notmatch "Running|Stopped|PowerOff"){
			Write-Log -text "$($masterImage) is in the state $($masterImageStatus). Attempting a repair..." -logFilePath $logfile -colour DarkCyan
			Repair-SCVirtualMachine -VM $masterImage -Force -Dismiss | Out-Null
			$masterImageStatus = (Get-SCVirtualMachine -Name $masterImage).Status
			$repairTries++
		}
	}until($masterImageStatus -match "Running|Stopped|PowerOff" -or $repairTries -gt 2)
	if($masterImageStatus -notmatch "Running|Stopped|PowerOff"){
		Write-Log -text "$($masterImage) is not in a good state ($($masterImageStatus))! Cancelling..." -logFilePath $logfile -colour Red
		Continue
	}

	$TargetImage = $null		
	$TargetImage = New-HypVMSnapshot -LiteralPath $VM.FullPath -SnapshotName "MCS_$($machineCatalogName)"
	# Restart the VM

	$startTries = 0	
		do{
			$startJob = $null
			Start-SCVirtualMachine -VM $masterImage -JobVariable startJob -ErrorAction SilentlyContinue | Out-Null
		        if($startJob.Status -eq "Failed"){
	        		Write-Log -text "Failed to start VM, pausing for 1 minute and refreshing... " -logFilePath $logfile -colour Red
				    Start-Sleep -Seconds 60
			        Repair-SCVirtualMachine -VM $masterImage -Force -Dismiss | Out-Null
				    $startTries++
			    }
	        }until($startJob.Status -ne "Failed" -or $startTries -gt 2 -or $masterImageStatus -eq "Running")
		if($startJob.Status -eq "Failed"){
			Write-Log -text "Failed to start VM after refreshing twice, must be a problem! Not critical though, so we will continue" -logFilePath $logfile -colour Yellow
		}
		Start-Sleep 15    

    if(!($TargetImage)){
        Write-Log -text "Snapshot variable is $($snapshot)" -logFilePath $logfile -colour Red
        Write-Log -text "Snapshot is equal to null? $($snapshot -eq $null)" -logFilePath $logfile -colour Red
        Write-Log -text "Snapshot either failed or snapshot variable didn't match an existing snapshot on master image $($masterImage)." -logFilePath $logfile -colour Red
        #$error[0]
        #pause
        Continue
    }
    
    # Change the provisioning scheme RAM 
    $currentProvSchemeRAM = (Get-ProvScheme -ProvisioningSchemename $machineCatalogName).MemoryMB
    Write-Log -text "Current provisioning scheme RAM set to $($currentProvSchemeRAM/1kb)GB - changing to 4GB temporarily" -logFilePath $logfile -colour DarkCyan
    Set-ProvScheme -ProvisioningSchemeName $machineCatalogName -VMMemoryMB 4096

    Write-Log -text "Updating Machine Catalog on $($storageResource)" -logFilePath $logfile -colour DarkCyan
    # Publish the image update to the machine catalog
    # http://support.citrix.com/proddocs/topic/citrix-machinecreation-admin-v2-xd75/publish-provmastervmimage-xd75.html
    $PubTask = Publish-ProvMasterVmImage -AdminAddress $adminAddress -MasterImageVM $TargetImage -ProvisioningSchemeName $machineCatalogName -RunAsynchronously
    $provTask = Get-ProvTask -AdminAddress $adminAddress -TaskId $PubTask

    # Better Progress bar
    do{
        $completion = $provTask.TaskExpectedCompletion - (Get-Date)
        $provTask = Get-ProvTask -AdminAddress $adminAddress -TaskId $PubTask
        Write-Progress -Activity "Updating provisioning scheme for $($machineCatalogName) - $([math]::Round($completion.TotalMinutes,0)) minutes remaining" -Status "$($provTask.TaskState) - $([int]$provTask.TaskProgress)%" -PercentComplete ([int]$provTask.TaskProgress)
        Start-Sleep 5
    }until($provTask.Active -eq $false)
    
    if($provTask.TaskState -ne "Finished"){
        Write-Error "The machine update task failed with error: $($provTask.TaskState). Changing Provscheme RAM back to $($currentProvSchemeRAM/1kb)GB then proceeding to next cluster..."
        Set-ProvScheme -ProvisioningSchemeName $machineCatalogName -VMMemoryMB $currentProvSchemeRAM
        Get-SCVMCheckpoint -VM $masterImage -MostRecent | Remove-SCVMCheckpoint | Out-Null
        Continue
    }elseif($provTask.TaskState -eq "Finished"){
        Write-Log -text "Setting provisioning scheme RAM back to $($currentProvSchemeRAM/1kb)GB" -logFilePath $logfile -colour DarkCyan
        Set-ProvScheme -ProvisioningSchemeName $machineCatalogName -VMMemoryMB $currentProvSchemeRAM
        Write-Log -text "Finished updating the machine catalog on $($storageResource)" -logFilePath $logfile -colour Green
        Get-SCVMCheckpoint -VM $masterImage -MostRecent | ? {$_.Name -like "MCS*"} | Remove-SCVMCheckpoint | Out-Null
    }
    # Start the desktop reboot cycle to get the update to the actual desktops
    # http://support.citrix.com/proddocs/topic/citrix-broker-admin-v2-xd75/start-brokerrebootcycle-xd75.html
    #Start-BrokerRebootCycle -AdminAddress $adminAddress -InputObject @($machineCatalogName) -RebootDuration 60 -WarningDuration 15 -WarningMessage $messageDetail -WarningTitle $messageTitle

    
}



# This will email a report to you upon completion.
$reportFilter = $machineCatalogBaseName

cd "C:\Scripts\MCSScripts"
.\MCS-Report.ps1 `
-filter $reportFilter `
-emailTo $emailTo `
-emailSubject "$($machineCatalogBaseName) Update Task"