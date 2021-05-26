Param(
    # Which MCS client
    [Parameter(Mandatory=$true)]
    [string]$client,

    # VMM Server
    [Parameter(Mandatory=$false)]
    [string]$VMMServer = 'oncvmm01.infra.saaas.com',

    # XD Controllers
    [Parameter(Mandatory=$false)]
    [string]$adminAddress = 'xadcsf01.corp.saaas.com', #The XD Controller we're going to execute against
    [Parameter(Mandatory=$false)]
    [array]$xdControllers = ('xadcsf01.corp.saaas.com','xadcsf02.corp.saaas.com','xadcsf01b.corp.saaas.com','xadcsf02b.corp.saaas.com'),

    # Hypervisor and storage resources
    [Parameter(Mandatory=$false)]
    [string]$hostResource = "ONCVMM01", # Name of your hosting connection

    # Other options
    [Parameter(Mandatory=$false)]
    [string]$mode = "fix",
    [Parameter(Mandatory=$false)]
    [string]$emailTo = "CitrixTeam@saaas.com"
)
#EndParamBlock

# Load the Citrix PowerShell modules
Write-Verbose "Loading Citrix XenDesktop modules."
if(!(Get-PSSnapin Citrix* -ea SilentlyContinue)){
    Add-PSSnapin Citrix*
}

# Find MCS Machine Catalogs matching the client name

$machineCatalogs = Get-BrokerCatalog -AdminAddress $adminaddress | ? {$_.Name -like "*$($client) - *" -and $_.ProvisioningType -eq "MCS"}
if(!($machineCatalogs)){
    Write-Host "Couldn't find any MCS catalogs matching the client name $($client), exiting!" -fore Red
    Exit
}

# Extract the Provisioning Schemes
$provSchemes = @()
$provSchemes += $machineCatalogs | % {Get-ProvScheme -ProvisioningSchemeUID $_.ProvisioningSchemeId -AdminAddress $adminaddress }

# Extract the Storage Repositories from these
$storageResources = @()
$storageResources += $provSchemes.HostingUnitName

# Only include catalogs in your zone - the Delivery Controllers in one zone probably don't have
#   access to the virtual hosts/VMM servers in the secondary zones, and we want to avoid 
#   unnecessary errors!
$zones = Get-ConfigZone
# Remove anything after a "." in the name of the adminAddress, in case FQDN has been used e.g. ctxcontroller.ctx.corp > ctxcontroller
$currentZone = $zones | ? {($adminAddress -replace "\..*") -in $_.ControllerNames}
if($currentZone){  
    #Write-Log -text "Found current zone for $($adminAddress) - $($currentZone.Description)" -logFilePath $logFile -colour DarkCyan
    # Get the storage resources in these connections
    $localStorageResources = gci XDHyp:\HostingUnits | ? {$_.HypervisorConnection.ZoneUID -eq $currentZone.Uid} 
    #Write-Log -text "Local Storage Resources: $($localStorageResources.PSChildName -join ", ")" -logFilePath $logFile -colour DarkCyan
    # Filter our list to just the local storage resources
    $storageResources = $storageResources | ? {$_ -in $localStorageResources.PSChildName}
    #Write-Log -text "Filtered Storage Resources list: $($storageResources -join ", ")" -logFilePath $logFile -colour DarkCyan

}else{
    Write-Host "Could not find a current zone for controller $($adminAddress)!" -fore Red
    Exit
}


# Extract the Machine Catalog Base Name
# regex to extract xxxVC00 (where xxx could be between 0 and 6 characters long, e.g. VC08 )
$machineCatalogBaseName = ($machineCatalogs | select -First 1).Name -replace " - [a-zA-Z]{0,6}VC[0-9]{2}"

# Extract the master image
#fancy regex to get only the "xa21vda01" out of a MasterImageVM string e.g. XDHyp:\HostingUnits\ONCVC16\xa21vda01.vm\snapshot01-01.snapshot
[regex]$regex = "[^\\]*\.vm"
$masterImageStr = ($provSchemes | ? {$_.HostingUnitName -in $storageResources} | Select -First 1).MasterImageVM
$masterImage = $regex.Match($masterImageStr) -replace "\.vm"

# Execute!

# needs to be run on Delivery Controller
cd "C:\Scripts\MCSScripts"

.\Update-MCSCatalog.ps1 `
-VMMServer $VMMServer `
-adminAddress $adminAddress `
-xdControllers $xdControllers `
-storageResources $storageResources `
-hostResource $hostResource `
-machineCatalogBaseName $machineCatalogBaseName `
-masterImage $masterImage `
-mode $mode `
-emailTo $emailTo

