#Requires -Version 5.1

<#
.SYNOPSIS
    Displays InfraOps Windows collector scheduled task status.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$ModulePath = Join-Path -Path $ScriptRoot -ChildPath 'Submit-InfraOpsInventory.ps1'
$RuntimeDirectory = Join-Path -Path $ScriptRoot -ChildPath 'runtime'
$HeartbeatPath = Join-Path -Path $RuntimeDirectory -ChildPath 'heartbeat.json'

if (Test-Path -Path $ModulePath) {
    . $ModulePath
    $TaskName = $Script:InfraOpsScheduledTaskName
}
else {
    $TaskName = 'InfraOps Windows Collector'
}

$Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

if (-not $Task) {
    Write-Host "Scheduled task '$TaskName' was not found."
    Write-Host 'Install the task with .\Install-CollectorSchedule.ps1'
    exit 0
}

$TaskInfo = Get-ScheduledTaskInfo -TaskName $TaskName

$LastRunTime = if ($TaskInfo.LastRunTime -and $TaskInfo.LastRunTime.Year -gt 1) {
    $TaskInfo.LastRunTime.ToString('yyyy-MM-dd HH:mm:ss')
}
else {
    'Never'
}

$NextRunTime = if ($TaskInfo.NextRunTime -and $TaskInfo.NextRunTime.Year -gt 1) {
    $TaskInfo.NextRunTime.ToString('yyyy-MM-dd HH:mm:ss')
}
else {
    'Not scheduled'
}

Write-Host 'Collector Scheduled Task Status'
Write-Host '-------------------------------'
Write-Host "Task Name      : $($Task.TaskName)"
Write-Host "Task State     : $($Task.State)"
Write-Host "Last Run Time  : $LastRunTime"
Write-Host "Last Result    : $($TaskInfo.LastTaskResult)"
Write-Host "Next Run Time  : $NextRunTime"

if (Test-Path -Path $HeartbeatPath) {
    try {
        $Heartbeat = Get-Content -Path $HeartbeatPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Host ''
        Write-Host 'Collector Heartbeat'
        Write-Host '-------------------'
        Write-Host "Last Run       : $($Heartbeat.lastRun)"
        Write-Host "Status         : $($Heartbeat.status)"
        if ($Heartbeat.runId) {
            Write-Host "Run ID         : $($Heartbeat.runId)"
        }
    }
    catch {
        Write-Warning "Unable to read heartbeat file: $HeartbeatPath"
    }
}
