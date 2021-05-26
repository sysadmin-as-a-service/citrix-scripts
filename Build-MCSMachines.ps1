#---------------------------------------------------------------------------
# Build MCS machines from MCS Catalog
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

    # MCS Catalog
    [Parameter(Mandatory=$true)]
    [string]$machineCatalogName,

    # Details on the machines you want built/updated
    [Parameter(ParameterSetName='addMachinesByCount',Mandatory=$false)]
    [ValidateRange(1,10)]
    [int]$noMachines,
    [Parameter(ParameterSetName='addMachinesByCount',Mandatory=$false)]
    $acctNameStartNumber = $null,
    [Parameter(ParameterSetName='addMachinesByName',Mandatory=$false)]
    $vdaName = $null,
    [Parameter(Mandatory=$false)]
    [switch]$addDHCPReservation = $true,
    [Parameter(Mandatory=$false)]
    $ipAddress = $null,
    [Parameter(Mandatory=$false)]
    $vmMAC = $null,
    [Parameter(Mandatory=$false)]
    $adNETBIOS = $env:USERDOMAIN,


    # Other options
    [Parameter(Mandatory=$false)]
    [string]$emailTo = "sysadmin@saaas.com"
)

#EndParamBlock

cd 'C:\Scripts\MCSScripts'

# Email Report Variables
$reportFilter = $machineCatalogName
# ----------

# Load the Citrix PowerShell modules
Write-Host "Loading Citrix & VMM modules." -fore Yellow
if(!(Get-PSSnapin Citrix* -ea SilentlyContinue)){
    Add-PSSnapin Citrix*
}
if(!(Get-Module VirtualMachineManager -ea SilentlyContinue)){
    Import-Module virtualmachinemanager
}

Write-Host "Attempting to connect to VMM..." -fore yellow -NoNewline
# Set up the connection to the SCVMM server
$vmmConnAttempts = 0
do{
    $vmmConn = Get-SCVMMServer -ComputerName $VMMServer -Credential $SCVMMCred
    if($vmmConn -eq $null){
        Write-Host "It seems the connection to VMM has failed, pausing a bit and then retrying..." -fore Red
        Start-Sleep -Seconds 60
        $vmmConnAttempts++
    }
}until($vmmConn -ne $null -or $vmmConnAttempts -gt 2)

if($vmmConn -eq $null){
    Write-Host "Couldn't connect to VMM! Emailing report and cancelling run." -ForegroundColor Red
    Send-MailMessage -To $emailTo -From "Citrix Reporting <$($env:computername)@$($env:userDNSdomain)>" -Subject "$($reportFilter) Build Task" -Body "The Update Task for $($reportFilter) failed, due to a VMM connection error" -SmtpServer mx-gslb.saaas.com
    Exit
}else{
    Write-Host "done!" -ForegroundColor Yellow
}


# Get Machine Catalog details

$machineCatalog = Get-BrokerCatalog -Name $machineCatalogName

# Create necessary new AD accounts, if you specify vdaName, it'll just create one account/one VM. 

$acctIDPool = Get-AcctIdentityPool  -AdminAddress $adminAddress -IdentityPoolName $machineCatalogName
if($vdaName -ne $null){
    Write-Host "Creating AD Account for $($vdaName)" -fore Yellow
    $adAccts= New-AcctADAccount  -AdminAddress $adminAddress -IdentityPoolName $machineCatalogName -ADAccountName $vdaName

}elseif($acctNameStartNumber -match "[0-9]"){
    Write-Host "Restting account identity pool $($machineCatalogName) to start at $($acctNameStartNumber)." -ForegroundColor Yellow
    $adAccts= New-AcctADAccount  -AdminAddress $adminAddress -Count $noMachines -IdentityPoolName $machineCatalogName -StartCount $acctNameStartNumber
}else{
    $adAccts= New-AcctADAccount  -AdminAddress $adminAddress -Count $noMachines -IdentityPoolName $machineCatalogName
}

foreach($adAcct in $adAccts.SuccessfulAccounts){
    
    $VDAName = $adAcct.ADAccountName -replace "$($adNETBIOS)\\" -replace "\$"
    if($ipAddress -eq $null){
        $ipAddress = "10.10.51.$([int]$VDAName.Substring(2,2))$([int]$VDAName.Substring(8,1))"
    }
    Write-Host "Creating new VM $($VDAName), IP address $($ipAddress)" -fore Yellow
    $buildTask = New-ProvVM  -ADAccountName $adAcct.ADAccountName -AdminAddress $adminAddress -ProvisioningSchemeName $machineCatalogName -RunAsynchronously
    do{
        $completion = $provTask.TaskExpectedCompletion - (Get-Date)
        $provTask = Get-ProvTask -AdminAddress $adminAddress -TaskId $buildTask.Guid
        Write-Progress -Activity "Building VDA $($VDAName) - $([math]::Round($completion.TotalMinutes,0)) minutes remaining" -Status "$($provTask.TaskState) - $([int]$provTask.TaskProgress)%" -PercentComplete ([int]$provTask.TaskProgress)
        Start-Sleep 5
    }until($provTask.Active -eq $false)

    if($provTask.TaskState -ne "Finished"){
        Write-Error "The creation task for $($VDAName) failed with error: $($provTask.TaskState). Cancelling..."
        Continue
    }elseif($provTask.TaskState -eq "Finished"){
        Write-Host "Finished creating the VM $($VDAName)!" -fore Green

    }
    Write-Host "Adding $($VDAName) to machine catalog" -fore Yellow
    New-BrokerMachine  -AdminAddress $adminAddress -CatalogUid $machineCatalog.Uid -MachineName $adAcct.ADAccountSid | Out-Null
    
    Write-Host "Setting CPU Compatibility mode to enabled" -ForegroundColor Yellow
    Set-SCVirtualMachine -VM $VDAName -CPULimitForMigration $true | Out-Null
    
    Write-Host "Adding blank SCSI adaptor" -fore Yellow
    New-SCVirtualScsiAdapter -VM $VDAName -RunAsynchronously | Out-Null

    Write-Host "Setting MAC address to static" -fore Yellow
    Get-SCVirtualNetworkAdapter -VM $VDAName | Set-SCVirtualNetworkAdapter -MACAddressType Static | Out-Null

    Write-Host "Setting memory to static" -fore Yellow
    Set-SCVirtualMachine -VM $VDAName -DynamicMemoryEnabled $false


    if($vmMAC -ne $null){
        # convert MAC from 001DD8B71C1E to 00-1D-D8-B7-1C-1E if it doesn't match that pattern
        if($vmMac -notmatch '..-..-..-..-..-..'){
            $vmMAC = ($vmMAC -replace '(..)','$1-').Trim('-')
        }
        Write-Host "Setting VM MAC address" -fore Yellow
        Get-SCVirtualNetworkAdapter -VM $VDAName | Set-SCVirtualNetworkAdapter -MACAddressType Static -MACAddress $vmMAC | Out-Null

    }


    if($addDHCPReservation){
        Write-Host "Adding DHCP reservation for $($VDAName), IP: $($ipAddress)" -ForegroundColor Yellow
        .\Add-DHCPReservation.ps1 `
        -ipAddress $ipAddress `
        -vm $VDAName `
    }

}

.\MCS-Report.ps1 `
-filter $reportFilter `
-emailTo $emailTo `
-emailSubject "$($machineCatalogName) Build Task"


