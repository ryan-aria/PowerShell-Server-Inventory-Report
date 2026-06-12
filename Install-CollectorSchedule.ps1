#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Installs the InfraOps Windows collector scheduled task.

.DESCRIPTION
    Reads scheduling settings from config.json and registers a Windows Scheduled Task
    that runs ServerInventoryReport.ps1 on a configurable interval.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$ModulePath = Join-Path -Path $ScriptRoot -ChildPath 'Submit-InfraOpsInventory.ps1'

if (-not (Test-Path -Path $ModulePath)) {
    Write-Error "Collector module not found: $ModulePath"
    exit 1
}

. $ModulePath

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path -Path $ScriptRoot -ChildPath 'config.json'
}

try {
    $Config = Get-CollectorConfig -ConfigPath $ConfigPath
}
catch {
    Write-Error $_
    exit 1
}

if (-not $Config.SchedulingEnabled) {
    Write-Warning 'Scheduling is disabled in config.json. Set Scheduling.Enabled to true to install the task.'
    exit 1
}

$FrequencyHours = $Config.SchedulingFrequencyHours
if ($FrequencyHours -lt 1) {
    Write-Error 'Scheduling.FrequencyHours must be at least 1.'
    exit 1
}

$CollectorScript = Join-Path -Path $ScriptRoot -ChildPath 'ServerInventoryReport.ps1'
if (-not (Test-Path -Path $CollectorScript)) {
    Write-Error "Collector script not found: $CollectorScript"
    exit 1
}

$TaskName = $Script:InfraOpsScheduledTaskName
$ExistingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

if ($ExistingTask) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed existing scheduled task '$TaskName'."
}

$Action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$CollectorScript`""

$RepetitionTrigger = New-ScheduledTaskTrigger `
    -Once `
    -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Hours $FrequencyHours) `
    -RepetitionDuration ([TimeSpan]::MaxValue)

$StartupTrigger = New-ScheduledTaskTrigger -AtStartup

$Principal = New-ScheduledTaskPrincipal `
    -UserId 'SYSTEM' `
    -LogonType ServiceAccount `
    -RunLevel Highest

$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 5)

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $Action `
    -Trigger @($RepetitionTrigger, $StartupTrigger) `
    -Principal $Principal `
    -Settings $Settings `
    -Description 'InfraOps Dashboard Windows inventory collector.' | Out-Null

Write-Host "Scheduled task '$TaskName' installed."
Write-Host "Frequency: every $FrequencyHours hour(s)"
Write-Host "Script: $CollectorScript"
