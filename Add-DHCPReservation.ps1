#---------------------------------------------------------------------------
# Sets a DHCP reservation for a VM based on its MAC address discovered from VMM
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


    #IP Address
    [Parameter(Mandatory=$true)]
    [string]$ipAddress = "10.10.51.141",
    
    #Master image
    [Parameter(Mandatory=$true)]
    [string]$vm, # Name of VM you're creating a reservation for

    [Parameter(Mandatory=$false)]
    [string]$dhcpServer = "localhost" # Name of DHCP server you're using



)
#EndParamBlock

Import-Module DHCPServer
Import-Module VirtualMachineManager

# Set up the connection to the SCVMM server
Get-SCVMMServer -ComputerName $VMMServer -Credential $SCVMMCred | Out-Null

$vmNetworkAdapter = (Get-SCVirtualMachine $vm).VirtualNetworkAdapters
if($vmNetworkAdapter.count -gt 1){
    Throw "More than one network adapter added to machine! I'm too lazy to deal with this."
}
if($vmNetworkAdapter.MACAddressType -eq "Dynamic"){
    Throw "MAC address on network adapter for $vm is Dynamic - need to change to STATIC"
}

$macAddress = $vmNetworkAdapter.MACAddress -replace ":"

Write-Host "Adding DHCP reservation for $($vm), MAC address $($macAddress) with IP address $($ipAddress)" -fore Yellow
if(Get-DhcpServerv4Reservation -IPAddress $ipAddress){
    # remove existing DHCP reservation if it exists!
    Write-Host "Removing existing DHCP reservation for $($ipAddress)" -fore Yellow
    Get-DhcpServerv4Reservation -IPAddress $ipAddress -ComputerName $dhcpServer | Remove-DhcpServerv4Reservation -ComputerName $dhcpServer 
    Reconcile-DhcpServerv4IPRecord -ComputerName $dhcpServer -ScopeId $scopeID -Force
}
Add-DhcpServerv4Reservation -ComputerName $dhcpServer -Name "$($vm).$($env:UserDNSDomain)" -Description "$($vm).$($env:UserDNSDomain)" -IPAddress $ipAddress -ClientId $macAddress -ScopeID $scopeID

Write-Host "Adding MAC address $($macAddress) to DHCP Allow Filter" -fore Yellow
Add-DhcpServerv4Filter -ComputerName $dhcpServer -List Allow -MacAddress $macAddress -Description "$($vm).$($env:UserDNSDomain)" -ErrorAction SilentlyContinue


Write-Host "Forcing replication of scope to partner server" -fore yellow
Invoke-DHCPServerv4FailoverReplication -Computername $dhcpServer -ScopeID $scopeID -Force
