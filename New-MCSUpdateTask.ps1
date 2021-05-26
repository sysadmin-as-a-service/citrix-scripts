param(
[string]$clientName = "test",
[string]$taskName = "Update Catalog",
[string]$taskTime = "05:00",
[string]$taskDay = "Friday",
[string]$taskScript = "C:\Scripts\MCSScripts\Quick-UpdateMCSCatalog.ps1",
[string]$svcAcct,
[string]$emailFrom = "john@example.com",
[string]$emailTo = "john@example.com",
[string]$smtpServer = "smtp.com"
)

##################################################################################
# Modify this script to have:
# 1. clientName - the name of your client - this should match your MCS Catalog, and ONLY the MCS catalog you want
# 2. taskTime - the time of day you want a catalog update to be started, 
#       in 24H format!
#       Recommended: 02:00
# 3. taskDay - the day of the week that you want to run the catalog update
#       Recommended: Friday, 5a.m.
##################################################################################

#########################################################################
# Create scheduled task for updating the catalog
#########################################################################

Write-Host "Creating Scheduled Task - $($clientName) - $($taskName) to be run at $($taskTime) on $($taskDay)."

$trigger = New-ScheduledTaskTrigger -At $taskTime -DaysOfWeek $taskDay -Weekly     
$action = New-ScheduledTaskAction -Execute 'Powershell.exe' -Argument "-ExecutionPolicy Bypass -File `"$($taskScript)`" -client `"$($clientName)`" -mode `"normal`""

Write-Host "Enter the password for your service account"
$cred = Get-Credential $svcAcct
Register-ScheduledTask -Action $action -Trigger $trigger -TaskName "$($clientName) - $($taskName)" -TaskPath "\Citrix\Update Catalog" -User $svcAcct -Password $cred.GetNetworkCredential().Password -RunLevel Highest

##################################################################################
# Notify
##################################################################################

Send-MailMessage -SmtpServer $smtpServer -To $emailTo -From $emailFrom -Subject "$($clientName) - New Scheduled Task Added" -Body `
"A new scheduled has been added for $($clientName):
Task Name: $($clientName) - $($taskName)
Run Time: $($taskTime)
Run Day: $($taskDay)
Task Script: $($taskScript)
"