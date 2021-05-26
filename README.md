# Scripts

These scripts are used to automate the provisioning, decommissioning, and update of Machine Creation Services Catalogs.
Also included is a reporting script to generate a status report, both post-update and at a point in time.

One significant feature is that these scripts support using one Master Image to update different MCS catalogs on different clusters. The Update-MCSCatalog.ps1 script will automatically migrate the master image to the next destination cluster.

This way, you can have one master image for a Delivery Group, but have the machines delivered from different fault domains (e.g. different cluster but in same VMM instance).

# How To Use
You should use these scripts to manage your whole MCS Catalog lifecycle. They will set up & name your catalogs in a consistent manner, which is then relied upon to perform other tasks like scripted updates.

## Update-Scripts.ps1

You can store all of these scripts on a web server or blob storage for easier access. Then, run Update-Scripts.ps1 and it will download all of the scripts onto the machine you're running this from - e.g., if you need to deploy the same update scripts across multiple Delivery Controllers or farms.

## Create-MCSCatalog.ps1

This is the first script to run, to create some MCS catalogs

## Build-MCSMachines.ps1

This will build VDAs from a previously built MCS Catalog, and optionally add a DHCP reservation for it

## Add-DHCPReservation.ps1

Adds a DHCP reservation to a Windows DHCP server and forces a sync to partner DHCP server

## Remove-MCSCatalog.ps1

For removing catalogs that are no longer required

## Update-MCSCatalog.ps1

Updates an MCS catalog with a specified master image (will shutdown the master image, so beware), then moves the master image to the next cluster in the list of MCS catalogs that needs it.

For example, if you have three MCS Catalogs for Client 01, on different fault domains:
- MCS Catalog - Client 01 - VC01
- MCS Catalog - Client 01 - VC03
- MCS Catalog - Client 01 - VC07

This will update the MCS Catalog where the master image currently resides (e.g. VC01), then move the master image to VC03, update the catalog there, then move the master image to VC07, and update the catalog there.]

## Quick-UpdateMCSCatalog.ps1

A simple wrapper script for Update-MCSCatalog.ps1. Pass in the name of a "client", which will filter the MCS Catalogs to update to any that match your input.

Don't put in something that matches multiple different catalogs, like "2016"... as this will update all MCS Catalogs matching the word "2016" with the same master image.

Also has a "-mode" switch, either "fix" or "normal". "fix" mode is for when you're re-running the script after a failed update, and it will only update catalogs that _haven't_ been updated in the last 24h.

## Restart-Servers.ps1

Handy script that restarts servers in a group, either based on some filters or an Active Directory OU. Can also choose to restart all "odd" servers or "even" servers (assumes you're using a XASERVER## naming format, with ## being two digits).

An advantage to this script is that it will shut down the VM, then reset the specs of the VM to match the ProvisioningScheme settings.

So if you have this scheduled as your weekly restart script, not only will it push out your required image updates, but if you want to change the compute specs of your VDAs, you can simply change your ProvisioningScheme RAM and CPU, and all the machines will update to use these values the next time they restart.

This was much more useful prior to hot memory add being released in Server 2016 :)

## MCS-Report.ps1

An HTML email report with all your catalogs & configurations, and then all the machines and their last image update time, last boot time, etc.