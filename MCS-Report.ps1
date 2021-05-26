[CmdletBinding()]
Param(
    [Parameter(Mandatory=$false)]
    [string]$filter,
    [Parameter(Mandatory=$false)]
    [string]$emailTo = "sysadmin@saaas.com",
    [Parameter(Mandatory=$false)]
    [string]$emailSubject = "Citrix MCS Report",
    [switch]$noEmail = $false,
    [string]$report = "all",
    [Parameter(Mandatory=$false)]
    [string]$emailSmtpServer = "mx-gslb.saaas.com",
    [Parameter(Mandatory=$false)]
    $emailFrom = "Citrix Reporting <xadcsf01@saaas.com>",
    [Parameter(Mandatory=$false)]
    $adminAddress = "xadcsf01"

)
#EndParamBlock

# static variables

$emailBody = @"
$body
"@

function Convert-UTCtoLocal

{
param(
[parameter(Mandatory=$true)]
[String] $UTCTime
)

$strCurrentTimeZone = (Get-WmiObject win32_timezone).StandardName
$TZ = [System.TimeZoneInfo]::FindSystemTimeZoneById($strCurrentTimeZone)
$LocalTime = [System.TimeZoneInfo]::ConvertTimeFromUtc($UTCTime, $TZ)
return $LocalTime
}

#####################
if(!(Get-PSSnapin Citrix* -ea SilentlyContinue)){
    Add-PSSnapin Citrix*
}





$header="<html>
<body>
<font size=""1"" face=""Verdana"">
<h3 align=""center"">Citrix MCS Report</h3>"

$Output = "<h5 align=""center"">Generated $((Get-Date).ToString())</h5></font><center><font size=""1"" face=""Verdana""><h5 align=""center"">Sysadmin As A Service Reporting</h5></font>"

if($report -eq "all" -or $report -eq "Catalogs"){

$provSchemes = @()
#fancy regex to get only the "xa21vda01" out of a MasterImageVM string e.g. XDHyp:\HostingUnits\ONCVC16\xa21vda01.vm\snapshot01-01.snapshot
[regex]$regex = "[^\\]*\.vm"

foreach($provS in (Get-ProvScheme | ? {$_.ProvisioningSchemeName -like "*$($filter)*"})){

    $lastUpdateAttempt = Get-ProvTask -Type PublishImage -Active $false -SortBy -DateStarted | ? {$_.ProvisioningSchemeUID -eq $provS.ProvisioningSchemeUID} | sort DateFinished -Desc | select -First 1 


    $provSchemes += ($provS | Select `
        @{n="CatalogName";e={(Get-BrokerCatalog -ProvisioningSchemeID $_.ProvisioningSchemeUid -AdminAddress $adminAddress).Name }},`
        HostingUnitName,`
        MachineCount,`
        DiskSize,`
        CPUCount,`
        MemoryMB,`
        @{n="MasterImage";e={ $regex.Match($_.MasterImageVM) -replace "\.vm"}},`
        MasterImageVMDate,`
        @{n="LastUpdateAttempt";e={$lastUpdateAttempt}}
    )
}

####################################
# Table - Provisioning Schemes
####################################

$Output+="<table border=""0"" cellpadding=""3"" width=""1100"" style=""font-size:9pt;color:white;font-family:Verdana""><tr bgcolor=""#004234""><th>Citrix MCS Catalog</th></table>"
$Output+="<table border=""0"" cellpadding=""3"" width=""1100"" style=""font-size:9pt;font-family:Verdana""><tr align=""center"" bgcolor=""#004234"">"
$Output+="<th>Catalog Name</th>"
$Output+="<th>Cluster</th>"
$Output+="<th>Machines</th>"
$Output+="<th>Disk Size (GB)</th>"
$Output+="<th>CPU Count</th>"
$Output+="<th>RAM (MB)</th>"
$Output+="<th>Master Image</th>"
$Output+="<th>Last Update</th>"
$Output+="<th>Last Update Attempt</th>"
$Output+="<th>Last Update Duration</th>"
$Output+="<th>Last Update Error</th>"
$Output+="</tr>"
$AlternateRow=0;
                        foreach ($provScheme in ($provSchemes | sort CatalogName)) {
                                    if($AlternateRow){
                                        $bgcolor = "#dddddd"
                                        $AlternateRow = 0
                                    }else{
                                        $bgcolor = ""
                                        $AlternateRow = 1
                                    }
                                    $Output+="<tr  style=""background-color:$($bgColor)"""                                    
                                    $Output+="><td align=""center"">$($provScheme.CatalogName)</td>"
				                    $Output+="<td align=""center"">$($provScheme.HostingUnitName)</td>"
                                    $Output+="<td align=""center"">$($provScheme.MachineCount)</td>"
                                    $Output+="<td align=""center"">$($provScheme.DiskSize)</td>"
                                    $Output+="<td align=""center"">$($provScheme.CpuCount)</td>"
                                    $Output+="<td align=""center"">$($provScheme.MemoryMB)</td>"
                                    $Output+="<td align=""center"">$($provScheme.MasterImage)</td>"
                                    if($provScheme.MasterImageVMDate -lt (Get-Date).AddDays(-5)){
                                        #image is older than 5 days
                                        $Output+="<td align=""center"" bgcolor=""#f04149"">$(Get-Date $provScheme.MasterImageVMDate -Format "ddd d MMM, h:mm tt")</td>"
                                    }elseif($provScheme.MasterImageVMDate -lt $provScheme.LastUpdateAttempt.DateStarted){
                                        #image isn't older than 5 days, but the last update attempt failed
                                        $Output+="<td align=""center"" bgcolor=""#ffa500"">$(Get-Date $provScheme.MasterImageVMDate -Format "ddd d MMM, h:mm tt")</td>"
                                    }else{
                                        $Output+="<td align=""center"" bgcolor=""$($bgcolor)"">$(Get-Date $provScheme.MasterImageVMDate -Format "ddd d MMM, h:mm tt")</td>"
                                    }
                                    $Output+="<td align=""center"">$(Get-Date $provScheme.LastUpdateAttempt.DateFinished -Format "ddd d MMM, h:mm tt")</td>"
                                    $Output+="<td align=""center"">$($d = New-TimeSpan -Start $provscheme.LastUpdateAttempt.DateStarted -End $provscheme.LastUpdateAttempt.DateFinished;)$($d.Hours)h, $($d.Minutes)m</td>"
                                    if($provScheme.LastUpdateAttempt.TerminatingError){
                                        $Output+="<td align=""center"" bgcolor=""#f04149"">$($provScheme.LastUpdateAttempt.TerminatingError)<br/><a href=`"http://$($adminAddress)/Director/Reports/$($provScheme.CatalogName -replace " - ONCVC[0-9]{2}")-Detailed.txt`">Click here for latest report</a></td>"
                                    }else{
                                        $Output+="<td align=""center"" bgcolor=""$($bgcolor)"">$($provScheme.LastUpdateAttempt.TerminatingError)<a href=`"http://$($adminAddress)/Director/Reports/$($provScheme.CatalogName -replace " - ONCVC[0-9]{2}")-Detailed.txt`">Click here for latest report</a></td>"
                                    }
				                    $Output+="</tr>";
#
			}

$Output+="<tr><td colspan=8>This table shows all MCS Catalogs and the last update details for them.<b> Catalogs with no update in the last 5 days will be highlighted in red. Catalogs with recent update failures will be in orange. </b></tr></td>"
$Output+="</table><br />"
}

if($report -eq "all" -or $report -eq "machines"){

$MCSMachines = Get-BrokerMachine -ProvisioningType MCS -AdminAddress $adminAddress| ? {$_.CatalogName -like "*$($filter)*"} | Select `
    MachineName,`
    CatalogName,`
    DesktopGroupName,`
    HostingServerName,`
    ImageOutOfDate,`
    @{n="ImageDate";e={Convert-UTCtoLocal -UTCTime ((Get-ProvVM -VMName $_.HostedMachineName).LastBootTime)}}, `
    @{n="RebootSchedule";e={ $_.Tags | % {(Get-BrokerRebootScheduleV2 -RestrictToTag $_ -AdminAddress $adminAddress)} }} `
    | Sort CatalogName

####################################
# Table - MCS Machines
####################################

$Output+="<table border=""0"" cellpadding=""3"" width=""1100"" style=""font-size:9pt;color:white;font-family:Verdana""><tr bgcolor=""#004234""><th>Citrix MCS Machines Report</th></table>"
$Output+="<table border=""0"" cellpadding=""3"" width=""1100"" style=""font-size:9pt;font-family:Verdana""><tr align=""center"" bgcolor=""#004234"">"
$Output+="<th>Machine Name</th>"
$Output+="<th>Catalog Name</th>"
$Output+="<th>Host</th>"
$Output+="<th>Desktop</th>"
$Output+="<th>Last Reboot Time</th>"
$Output+="<th>Reboot Schedule</th>"
$Output+="<th>Reboot Time</th>"
$Output+="</tr>"
$AlternateRow=0;
                        foreach ($MCSMachine in ($MCSMachines | sort MachineName)) {
                                    if($AlternateRow){
                                        $bgcolor = "#dddddd"
                                        $AlternateRow = 0
                                    }else{
                                        $bgcolor = ""
                                        $AlternateRow = 1
                                    }
                                    
                                    $Output+="<tr  style=""background-color:$($bgColor)"""
                                    $Output+="><td align=""center"">$($MCSMachine.MachineName)</td>"
				                    $Output+="<td align=""center"">$($MCSMachine.CatalogName)</td>"
                                    $Output+="<td align=""center"">$($MCSMachine.HostingServerName)</td>"
                                    $Output+="<td align=""center"">$($MCSMachine.DesktopGroupName)</td>"
                                    if($MCSMachine.ImageOutOfDate -eq $true -and ($MCSMachine.ImageDate -lt (Get-Date).adddays(-14))){
                                        $Output+="<td align=""center"" bgcolor=""#f04149"">$(Get-Date $MCSMachine.ImageDate -f "ddd d MMM, h:mm tt")</td>"
                                    }elseif($MCSMachine.ImageOutOfDate -eq $true -and ($MCSMachine.ImageDate -gt (Get-Date).adddays(-14))){
                                        $Output+="<td align=""center"" bgcolor=""#FFFF66"">$(Get-Date $MCSMachine.ImageDate -f "ddd d MMM, h:mm tt")</td>"                             
                                    }else{
                                        $Output+="<td align=""center"" bgcolor=""$($bgcolor)"">$(Get-Date $MCSMachine.ImageDate -f "ddd d MMM, h:mm tt")</td>"
                                    }
                                    $Output+="<td align=""center"">$($MCSMachine.RebootSchedule.Name)</td>"
									$Output+="<td align=""center"">$($MCSMachine.RebootSchedule.Day) - $($MCSMachine.RebootSchedule.StartTime.ToString())</td>"
                                    $Output+="</tr>";
			}
$Output+="<tr><td colspan=8>This table shows all MCS Machines and if they have a scheduled reboot or an update pending. <br/> Yellow = Update pending but less than 2 weeks old. Red = Update pending and older than 2 weeks <br/><b>Machines with an update pending should be drainstopped and restarted.</b></tr></td>"
$Output+="</table><br />"
}

################## END
$body = $header
$body += $output

$body | Out-File "\\$($adminAddress)\C$\inetpub\wwwroot\Director\Reports\MCS-Report$($filter).txt" -Force

if($noEmail){
	Write-Host "Skipping email sending"
}else{
	Send-MailMessage -To $emailTo -From $emailFrom -Subject $emailSubject -Body $Body -BodyAsHTML -SmtpServer $emailSmtpServer
}

