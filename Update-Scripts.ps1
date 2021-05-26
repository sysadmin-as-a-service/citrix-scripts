$proxy = $null
$proxyCred = $null
$blobBaseURL = "https://mystoragecontainer.blob.core.windows.net/citrix/mcsscripts/"
$scripts = 
"Restart-Servers.ps1",
"Update-MCSCatalog.ps1",
"Create-MCSCatalog.ps1",
"Quick-UpdateMCSCatalog.ps1",
"Remove-MCSCatalog.ps1",
"Add-DHCPReservation.ps1",
"Build-MCSMachines.ps1",
"MCS-Report.ps1",
"Add-DHCPReservation.ps1",
"New-MCSUpdateTask.ps1"

if(!(Test-Path C:\Scripts\MCSScripts)){
    mkdir C:\Scripts\MCSScripts
}

cd C:\Scripts\MCSScripts
foreach($script in $scripts){
    if(!(Test-Path "Downloads")){
        mkdir "Downloads"
    }

    #Download all scripts from blob
    Write-Host "Downloading $($script)" -f Yellow
    $result = Invoke-WebRequest -Uri "$($blobBaseURL)$($script)" -OutFile "C:\Scripts\MCSScripts\Downloads\$($script)" -PassThru -Proxy $proxy -ProxyCredential $proxyCred
    if($result.StatusDescription -ne "OK"){
	Write-Host "Something failed. Quit now!!" -f REd
	exit
    }
    #Check if script already exists
    if(Test-Path "C:\Scripts\MCSScripts\$($script)"){
        # do the param swapping

        $existingScript = Get-Content "C:\Scripts\MCSScripts\$($script)"
        
        # find the first line that is just ) - most likely our param block ending
        $existingScriptParamStartBlock = ($existingScript | Select-String "^param\($" | Select -f 1).LineNumber
        $existingScriptParamEndBlock = ($existingScript | Select-String "^\)$" | Select -f 1).LineNumber
        $existingScriptParamBlockLength = $existingScriptEndParamBlock - $existingScriptStartParamBlock
        
        $newScript = Get-Content "C:\Scripts\MCSScripts\Downloads\$($script)"
        # find the first line that is just ) - most likely our param block ending
        $newScriptParamStartBlock = ($newScript | Select-String "^param\($" | Select -f 1).LineNumber
        $newScriptParamEndBlock = ($newScript | Select-String "^\)$" | Select -f 1).LineNumber
        $newScriptParamBlockLength = $newScriptEndParamBlock - $newScriptStartParamBlock

        if($existingScriptParamBlockLength -ne $newScriptParamBlockLength){
            #Send warning!
            Send-MailMessage -From "MCS Script Updater $($env:COMPUTERNAME)@saaas.com" -To "sysadmin@saaas.com" -Subject "Script Updater Issue - $($script)" -Body "Warning! Have updated $($script) and the existing param block doesn't match the new param block."
        }

        # our new script will be combination of the old param block and the new script contents 
        # need to check if these are different lengths...
        Write-Host "Updating $($script) with existing param block" -f Yellow
        $updatedScript = $existingScript[0..($existingScriptParamEndBlock-1)] + $newScript[($newScriptParamEndBlock)..$newScript.Length]
        $updatedScript | Out-File "C:\Scripts\MCSScripts\$($script)" -Force
    }else{      
        # New script, just move the script into the MCSScripts dir
        Write-Host "Updating $($script)" -f Yellow
        Move-Item "C:\Scripts\MCSScripts\Downloads\$($script)" "C:\Scripts\MCSScripts\$($script)"
        Unblock-File "C:\Scripts\MCSScripts\Downloads\$($script)"
    }

}

