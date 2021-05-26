############################################################################
# Restart Servers
# This script will restart MCS machines
############################################################################

param(
    [string]$restartGroup = "Odd",
    [int]$restartWarning = 15,
    [string]$restartMessage = "This server is being restarted for maintenance. Please save your work and log off.", 
    [switch]$tee,
    [switch]$whatIf,
    [string]$adFilter = ".*",
    [string]$adOU = "OU=MCS Nodes,OU=Citrix Servers,OU=Servers,DC=corp,DC=saaas,DC=com",
    [string]$adDomain = "SAAAS",

    # VMM Server
    [Parameter(Mandatory=$false)]
    [string]$VMMServer = 'oncvmm01.infra.saaas.com',
    [Parameter(Mandatory=$false)]
    [System.Management.Automation.PSCredential]$SCVMMCred = (New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList "INFRA\Administrator",(Get-Content "\\XADCSF01\C$\Scripts\MCSScripts\MCSCredential.txt" | ConvertTo-SecureString -Key (get-content "\\XADCSF01\C$\Scripts\MCSScripts\AES.key"))),
    [Parameter(Mandatory=$false)]
    [string]$vhostFQDN = ".infra.saaas.com",

    #Email
    [Parameter(Mandatory=$false)]
    [string]$emailTo = "sysadmin@saaas.com",
    [Parameter(Mandatory=$false)]
    [string]$emailFrom = "Citrix Reporting - ONS <xadcsf01@corp.saaas.com>",
    [Parameter(Mandatory=$false)]
    [string]$emailSubject = "Citrix MCS - Restart Servers",
    [Parameter(Mandatory=$false)]
    [string]$smtpServer = "mx-gslb.saaas.com",

    [Parameter(Mandatory=$false)]
    [string]$logFile = "\\XADCSF01\C$\Scripts\MCSScripts\Reports\Restart-Servers.log",
    [Parameter(Mandatory=$false)]
    [string]$deliveryController = "XADCSF01"


)
#EndParamBlock

############################################################################
# Logging
############################################################################


function Write-Log {
param(
	[string]$text,
	[string]$colour = "White",
	[bool]$append = $true
)

if($append){
    "$(Get-Date -f g) - $($text)" | Out-File -FilePath $logFile -Append 
}else{
	"$(Get-Date -f g) - $($text)" | Out-File -FilePath $logFile
}
    Write-Host "$(Get-Date -f g) - $($text)" -fore $colour
}


Write-Log "Starting Restart script" -append $false
foreach($param in $MyInvocation.BoundParameters.Keys){
    Write-Log "$($param)  =  $($MyInvocation.BoundParameters[$param])"
}


Write-Log "Loading PowerShell modules."
if(!(Get-PSSnapin Citrix* -ea SilentlyContinue)){
    Add-PSSnapin Citrix*
}
if(!(Get-Module VirtualMachineManager -ea SilentlyContinue)){
    Import-Module virtualmachinemanager
}
if(!(Get-Module ActiveDirectory)){
    Import-Module ActiveDirectory
}


# Set up the connection to the SCVMM server
Write-Log "Connecting to VMM"
$vmmConnAttempts = 0
do{
    $vmmConn = Get-SCVMMServer -ComputerName $VMMServer -Credential $SCVMMCred
    if($vmmConn -eq $null){
        Write-Log "It seems the connection to VMM has failed, pausing a bit and then retrying..." -colour Red
        Start-Sleep -Seconds 60
        $vmmConnAttempts++
    }
}until($vmmConn -ne $null -or $vmmConnAttempts -gt 2)

if($vmmConn -eq $null){
    Write-Log "Couldn't connect to VMM! Emailing report and cancelling run." -colour Red
    Send-MailMessage -To $emailTo -From $emailFrom -Subject "$($reportFilter) Restart Task" -Body "The Restart Task for $($reportFilter) failed, due to a VMM connection error" -SmtpServer mx-gslb.saaas.com
    Exit
}



############################################################################
# Start
############################################################################

if($whatIf -eq $true){
    Write-Log "Test mode is TRUE, pausing for 10s." -colour Yellow
    Start-Sleep 10
}else{
    Write-Log "Test mode is FALSE, pausing for 10s." -colour Yellow
    Start-Sleep 10
}



############################################################################
# Get servers and current maint. mode status
############################################################################
Write-Log "Getting list of servers."
$servers = @()
foreach($adServer in (Get-ADComputer -SearchBase $adOU -SearchScope Subtree -Filter * | ? {$_.Name -match $adFilter})){
    #Skip restarting the server if it isn't in Get-BrokerMachines
    if(!(Get-BrokerMachine -MachineName "$($adDomain)\$($adServer.Name)" -ErrorAction SilentlyContinue)){
        Write-Log "Couldn't add $($adDomain)\$($adServer.Name) - isn't in a Citrix Machine Catalog"
    }else{
    
        $servers += [PSCustomObject]@{ `
            Server=$adServer.Name; `
            InMaintenanceMode = (Get-BrokerMachine -MachineName "$($adDomain)\$($adServer.Name)" | select InMaintenanceMode).InMaintenanceMode; `
            PendingUpdate = (Get-BrokerMachine -MachineName "$($adDomain)\$($adServer.Name)" | select ImageOutOfDate).ImageOutOfDate; `
            vmSuffix = $adServer.Name.Substring($adServer.Name.Length - 2,2) -replace "A|B|C";
            restartGroup = if(($adServer.Name.Substring($adServer.Name.Length - 2,2) -replace "A|B|C") % 2 -eq 0){"Even"}else{"Odd"};
            IsPhysical = (Get-BrokerMachine -MachineName "$($adDomain)\$($adServer.Name)" | select IsPhysical).IsPhysical; `
        }
    }        
}

if($restartGroup -eq "All"){
    # Don't shrink the servers group
}elseif($restartGroup -match "Even|Odd"){
    # Else, only include those servers that are Even/Odd
    $servers = $servers | ? {$_.restartGroup -eq $restartGroup}
}
# Sort the servers by name
$servers = $servers | sort Server

Write-Log "Found $($servers.count) servers to restart:"
foreach($server in $servers){
    Write-Log "`n$($server.Server)"
}
############################################################################
# Put servers into maintenance mode, get list of all sessions
############################################################################
#Write-Log "Putting servers into maintenance mode."
Write-Log "Skipping putting servers into maintenance mode, as this has caused issues in the past!"
$sessions = @()

foreach($server in $servers){
    if($server.InMaintenanceMode -eq $false){
        #Write-Log "Putting $($server.Server) into maintenance mode"
        Write-Log "$($server.Server) isn't in maintenance mode, we won't change this."
        if(!($whatIf)){
            # Do nothing - putting in maintenance mode causes issues if the script fails
            #Set-BrokerMachine -MachineName "$($adDomain)\$($server.Server)" -InMaintenanceMode $true
        }
    }

    $sessions += Get-BrokerSession -MachineName "$($adDomain)\$($server.Server)" 
    
}

############################################################################
# Message currently logged in users
############################################################################
Write-Log "Reboot warning message is $($restartMessage)."
Write-Log "Sending reboot warning message to $($sessions.count) sessions."

$sessions = @()
foreach($session in $sessions){
    if(!($whatIf)){
        Send-BrokerSessionMessage -InputObject $session -MessageStyle Information -Title "Server Reboot" -Text $restartMessage
    }
}

############################################################################
# Wait for restartWarning time
############################################################################


Write-Log "Sleeping for $($restartWarning) minutes."
$sleepTime = $restartWarning * 60
Start-Sleep -Seconds $sleepTime
#Start-Sleep -Seconds 900

############################################################################
# Restart servers
############################################################################

# Start the restart task for each server



foreach($server in $servers){
    # Set fix specs to false initially
    $fixSpecs = $false

    # Get Prov scheme specs
    $provScheme = Get-ProvScheme -ProvisioningSchemeName (Get-ProvVM -VMName $server.Server).ProvisioningSchemeName
    $provSchemeCPU = $provScheme.CpuCount
    $provSchemeRAM = $provScheme.MemoryMB

    # Get VM specs
    $vm = Get-SCVirtualMachine -Name $server.Server 
    $vmCPU = $vm.CPUCount
    $vmRAM = $vm.MemoryAssignedMB
    $vmStopAction = $vm.StopAction

    if((($provSchemeCPU -ne $vmCPU) -or ($provSchemeRAM -ne $vmRAM) -or ($vmStopAction -notmatch "TurnOffVM|ShutdownGuestOS" )) -and $provScheme -ne $null -and $provSchemeRam -ge "8192"){
    #if((($provSchemeCPU -ne $vmCPU) -or ($provSchemeRAM -ne $vmRAM) -or ($vmStopAction -notmatch "TurnOffVM|ShutdownGuestOS" )) -and $provScheme -ne $null){
        Write-Log "Specs for server $($server.Server) aren't the same as the provisioning scheme!" -colour Yellow
        Write-Log "Prov Scheme CPU: $($provSchemeCPU)"
        Write-Log "Prov Scheme RAM: $($provSchemeRAM)"
        Write-Log "VM CPU: $($vmCPU)"
        Write-Log "VM RAM: $($vmRAM)"
        Write-Log "VM Stop Action: $($vmStopAction)"
        Write-Log "Changing VM specs to $($provSchemeCPU) CPU and $($provSchemeRAM)MB RAM, and Stop Action to ShutdownGuestOS"
                
    }else{
        Write-Log "Specs for $($server.Server) are accurate - no need to change."
        Continue
    }

    # Everything below this point ONLY RUNS IF THE MACHINE SPECS NEED CHANGING
    # (the Continue function above tells the script to go to the next $server in $servers)


    Write-Log "Restarting $($server.Server)"
    $restartAction = $null
    if(!($whatIf)){
        
        # Shut down the VM, so it doesn't update the image in a "crashed" state
    	Write-Log "Checking if $($server.Server) is ready to be shut down" -colour DarkCyan
    	$repairTries = 0
    	do{
		    $vmStatus = (Get-SCVirtualMachine -Name $server.Server).Status
		    if($vmStatus -notmatch "Running|Stopped|PowerOff"){
    			Write-Log "$($server.Server) is in the state $($vmStatus). Attempting a repair..." -colour DarkCyan
			    Repair-SCVirtualMachine -VM $server.server -Force -Dismiss | Out-Null
			    $vmStatus = (Get-SCVirtualMachine -Name $Server.Server).Status
			    $repairTries++
		    }
	    }until($vmStatus -match "Running|Stopped|PowerOff" -or $repairTries -gt 2)
	    if($vmStatus -notmatch "Running|Stopped|PowerOff"){
		    Write-Log "$($server.Server) is not in a good state ($($vmStatus))! Cancelling..." -colour Red
		    Continue
	    }

        Write-Log "Stopping $($server.Server) " -colour DarkCyan
	    $vmStatus = (Get-SCVirtualMachine -Name $server.Server).Status
	    if($vmStatus -ne "PowerOff"){
		    $stopTries = 0	
		    do{
			    $stopJob = $null
			    Stop-SCVirtualMachine -VM $server.Server -Shutdown -JobVariable StopJob -ErrorAction SilentlyContinue | Out-Null
		            if($stopJob.Status -eq "Failed"){
	        		    Write-Log "Failed to stop VM, pausing for 10 minutes and refreshing... this is most often due to an current backup or replication job."  -Color Red
				        Start-Sleep -Seconds 600
			            Repair-SCVirtualMachine -VM $server.Server -Force -Dismiss | Out-Null
				        $stopTries++
			    }
	            }until($stopJob.Status -ne "Failed" -or $stopTries -gt 2 -or $vmStatus -eq "PowerOff")
		    if($stopJob.Status -eq "Failed"){
			    Write-Log "Failed to stop VM after refreshing twice, must be a critical error!" -colour Red
			    Continue
		    }
		    Start-Sleep 15
	    }

        # Try changing VM specs now
        If ($provSchemeRAM -gt "4096"){
        Set-SCVirtualMachine -VM $server.Server -CPUCount $provSchemeCPU -MemoryMB $provSchemeRAM -StopAction "ShutdownGuestOS" | Out-Null
        }

        # Restart VM
	    $startTries = 0	
		do{
			$startJob = $null
			Start-SCVirtualMachine -VM $server.Server -JobVariable startJob -ErrorAction SilentlyContinue | Out-Null
		        if($startJob.Status -eq "Failed"){
	        		Write-Log "Failed to start VM, pausing for 1 minute and refreshing... "  -colour Red
				    Start-Sleep -Seconds 60
			        Repair-SCVirtualMachine -VM $server.Server -Force -Dismiss | Out-Null
				    $startTries++
			    }
	        }until($startJob.Status -ne "Failed" -or $startTries -gt 2 -or $vmStatus -eq "Running")
		if($startJob.Status -eq "Failed"){
			Write-Log "Failed to start VM after refreshing twice, must be a problem! Not critical though, so we will continue"  -colour Yellow
		}
		Start-Sleep 15  
        Write-Log "Started VM $($server.Server) successfully"        
        $vm = Get-SCVirtualMachine -Name $server.Server
        $vmCPU = $vm.CPUCount
        $vmRAM = $vm.MemoryAssignedMB
        Write-Log "VM specs have been changed:"
        Write-Log "VM CPU: $($vmCPU)"
        Write-Log "VM RAM: $($vmRAM)"



    }else{
        #whatif mode, do nothing
    }
}

$servers | Add-Member -MemberType NoteProperty -Name RestartTask -Value $null
$servers | Add-Member -MemberType NoteProperty -Name RestartAttempt -Value 0


do{
    # Create a restart action for all servers that we have attempted 3 times or less, and that haven't completed yet
    #  at first, this will restart all servers (as attempts will be = 0, and RestartTask = $null)
    #  Once our first restart pass has completed, it will only target servers that have been attempted < 4 times and
    #  haven't completed successfully
    foreach($server in ($servers | ? {$_.RestartAttempt -lt 4 -and $_.RestartTask.State -ne "Completed"}) ){
        $server.RestartAttempt++
            if($server.IsPhysical -eq $true){
                Write-Log "Restarting $($server.Server) manually (non-powermanaged server)"
                $restartAction = Restart-Computer -ComputerName $server.Server -Wait -Force
                $server.RestartTask = ([PSCustomObject]@{State="Completed";FailureReason=$null})
            }else{
                $restartAction = New-BrokerHostingPowerAction -MachineName "$($adDomain)\$($server.Server)" -Action Restart
                $server.RestartTask = $restartAction
                Write-Log "Restart task ID for $($server.Server) is $($server.RestartTask.uid)"
            }

    }

    # Update the status of the broker hosting power action until they're all either Completed or Failed
    Write-Log "Getting status of restart tasks."

    do{
        foreach($server in $servers){
            if($server.RestartTask.State -notmatch "Completed|Failed"){
                if(!($whatIf)){
                    $server.RestartTask = Get-BrokerHostingPowerAction -Uid $server.RestartTask.Uid
                }
                Write-Log "$($server.Server) restart task is in state: $($server.RestartTask.State)."
            }
        }
    
        Start-Sleep -Seconds 60

    }until(!($servers | ? {$_.RestartTask.State -notmatch "Completed|Failed"}))

}until( !($servers | ? { ($_.RestartTask.State -notmatch "Completed") -or ($_.RestartAttempt -gt 3)}) )


Write-Log "All restart tasks have ended."

# Write to log on status of restart tasks and take servers out of maint mode again
foreach($server in $servers){
    if($server.RestartTask.State -eq "Failed"){
        Write-Log "Failed to restart $($server.Server). Failure reason is $($server.RestartTask.FailureReason)."
    }elseif($server.RestartTask.State -eq "Completed"){
        Write-Log "Restarted $($server.Server). Restart task result was $($server.RestartTask.State)."
    }
    
    #If the server wasn't in maintenance mode before, take it out
    if($server.InMaintenanceMode -eq $false){
        Write-Log "Taking $($server.server) out of maintenance mode again."
        if(!($whatIf)){
            $i = 0
            do{
                $i++
                Write-Log "Attempting to take $($server.Server) out of maintenance mode - attempt $($i)"
                Set-BrokerMachine -MachineName "$($adDomain)\$($server.Server)" -InMaintenanceMode $false
                #Check that it worked
                Start-Sleep -Seconds 5
                $server.InMaintenanceMode = (Get-BrokerMachine -MachineName "$($adDomain)\$($server.Server)").InMaintenanceMode
            }until($server.InMaintenanceMode -eq $false -or $i -gt 3)
            if($server.InMaintenanceMode -eq $true){
                Write-Log "Failed to take $($server.Server) out of maintenance mode!"
            }

        }
    }elseif($server.InMaintenanceMode -eq $true){
        Write-Log "$($server.Server) was already in maintenance mode, leaving in maintenance mode."
    }

}

############################################################################
# Send email & log
############################################################################

Send-MailMessage -SmtpServer $smtpServer -From $emailFrom -to $emailTo -Subject $emailSubject -Attachments $script:logFile
cd "\\$($deliveryController)\c`$\Scripts\MCSScripts"
.\MCS-Report.ps1 `
-emailTo $emailTo `
-emailSubject $emailSubject `
-report "machines"