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

    # Catalog
    [Parameter(Mandatory=$true)]
    [string]$machineCatalogName

)
#EndParamBlock

Write-Host "WARNING!! You are about to destroy an MCS Catalog and associated machines. This will not check for active users etc., are you sure you know what you're doing???" -ForegroundColor Red
pause

# Script to remove an MCS Catalog

cd '\\XADCSF01\C$\Scripts\MCSScripts'

# Load the Citrix PowerShell modules
Write-Verbose "Loading Citrix, VMM & DHCP modules."
if(!(Get-PSSnapin Citrix* -ea SilentlyContinue)){
    Add-PSSnapin Citrix*
}
if(!(Get-Module VirtualMachineManager -ea SilentlyContinue)){
    Import-Module virtualmachinemanager
}
if(!(Get-Module DHCPServer -ea SilentlyContinue)){
    Import-Module DHCPServer
}

# Set up connection to VMM
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
    Write-Host "Couldn't connect to VMM! Cancelling." -ForegroundColor Red
    Exit
}


# Getting list of VDAs
$machineCatalogBaseName = ($machineCatalogName -replace " - VC[0-9]{2}")
$machineCatalog = Get-BrokerCatalog -Name $machineCatalogName
$provScheme = Get-ProvScheme -ProvisioningSchemeName $machineCatalogName
$acctIDPool = Get-AcctIdentityPool -IdentityPoolName $machineCatalogName
$brokerMachines = Get-BrokerMachine -CatalogName $machineCatalogName

foreach($vda in $brokerMachines){
    $vdaName = $vda.DNSName -replace "\..*"
    

# Put all VDAs into maintenance mode
    Set-BrokerMachine -MachineName $vda.MachineName -InMaintenanceMode $true
# Shut down all VDAs
    Stop-SCVirtualMachine -VM $vdaName -Force | Out-Null
# Get VDA IP addresses
    $ipAddress = (Resolve-DnsName $vda.DNSName).IPAddress
# Get VDA MAC addresses 
    $vdaMAC = ((Get-SCVirtualMachine -Name $vdaName).VirtualNetworkAdapters[0]).MACAddress -replace ":"

# Check for DHCP reservations. Delete if they exist?
    if(Get-DHCPServerv4Reservation -IPAddress $ipAddress -ErrorAction SilentlyContinue){
        Write-Host "Removing DHCP Reservation for $($ipAddress)" -fore Yellow
        Get-DHCPServerv4Reservation -IPAddress $ipAddress | Remove-DHCPServerv4Reservation
        Write-Host "Forcing replication of scope to partner server" -fore yellow
        Invoke-DHCPServerv4FailoverReplication -Computername localhost -ScopeID 10.10.48.0 -Force
    }

    Write-Host "Removing VDA:`nVDA Name: $($vdaName)`nMachine Name:$($vda.MachineName)`nIP Address:$ipAddress`nMAC:$vdaMAC`nDesktop Group:$vda.DesktopGroupName" -fore Yellow

# Destroy machine
    
    Write-Host "Removing $($vdaName) from Delivery Group $($vda.DesktopGroupName)" -fore Yellow
    Remove-BrokerMachine  -AdminAddress $adminAddress -MachineName $vda.MachineName -DesktopGroup $vda.DesktopGroupName

    Write-Host "Removing $($vdaName) from Machine Catalog $($machineCatalogName)" -ForegroundColor Yellow
    Remove-BrokerMachine  -AdminAddress $adminAddress -Force -MachineName $vda.MachineName            

    Write-Host "Renaming and deleting VM $($vdaName)" -ForegroundColor Yellow
    Remove-ProvVM  -AdminAddress $adminAddress -ProvisioningSchemeName $machineCatalogName -VMName $vdaName
    Get-SCVirtualMachine -Name $vdaName | Set-SCVirtualMachine -Name "OFF_$($vdaName)"

    Write-Host "Deleting AD Account $($vda.MachineName)" -fore Yellow
    Remove-AcctADAccount  -ADAccountName "$($vda.MachineName)`$" -AdminAddress $adminAddress -Force -IdentityPoolName $machineCatalogName -RemovalOption "Delete"
  
}

# Get master image? this will be needed if we are recreating catalog
$masterImage = ($provScheme.MasterImageVM -split "\\" -split "\.vm")[3]
    
# Destroy master image
Write-Host "Deleting VM $($masterImage)" -ForegroundColor Yellow
Get-SCVirtualMachine -Name $masterImage | Remove-SCVirtualMachine 
Write-Host "Deleting Master Image AD Account" -fore Yellow
Get-ADComputer $masterImage | Remove-ADComputer


# Remove Machine Catalog, acctIdPool, ProvScheme etc.
Write-Host "Removing Machine Catalog: $($machineCatalogName)" -fore Yellow
Get-BrokerCatalog -Name $machineCatalogName | Remove-BrokerCatalog
Write-Host "Removing Account Identity Pool: $($machineCatalogName)" -fore Yellow
Get-AcctIdentityPool -IdentityPoolName $machineCatalogName | Remove-AcctIdentityPool
Write-Host "Removing Provisioning Scheme: $($machineCatalogName)" -fore Yellow
# Remove the provisioning scheme - ForgetVMs is more reliable but may result in VMs being left over
Get-ProvScheme -ProvisioningSchemeName $machineCatalogName | Remove-ProvScheme -ForgetVM
#Get-ProvScheme -ProvisioningSchemeName $machineCatalogName | Remove-ProvScheme

