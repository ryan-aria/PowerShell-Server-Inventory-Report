#Requires -Version 5.1

<#
.SYNOPSIS
    Removes the InfraOps Windows collector scheduled task.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$ModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Submit-InfraOpsInventory.ps1'

if (Test-Path -Path $ModulePath) {
    . $ModulePath
    $TaskName = $Script:InfraOpsScheduledTaskName
}
else {
    $TaskName = 'InfraOps Windows Collector'
}

$ExistingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

if (-not $ExistingTask) {
    Write-Host "Scheduled task '$TaskName' was not found."
    exit 0
}

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
Write-Host "Scheduled task '$TaskName' removed."
