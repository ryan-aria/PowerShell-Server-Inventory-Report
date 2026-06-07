#Requires -Version 5.1

<#
.SYNOPSIS
    Generates a server inventory report and exports results to CSV and HTML.

.DESCRIPTION
    PowerShell Server Inventory Report v1.0
    Collects system, hardware, BIOS, CPU, uptime, and disk information from
    the local computer using CIM and Get-Volume. Exports a combined inventory
    report to CSV and a formatted HTML report for documentation and auditing.

.PARAMETER OutputPath
    Directory where InventoryReport.csv and InventoryReport.html will be saved.
    Defaults to the reports folder in the script directory.

.EXAMPLE
    .\ServerInventoryReport.ps1
    Generates reports in the default .\reports folder.

.EXAMPLE
    .\ServerInventoryReport.ps1 -OutputPath 'C:\Reports'
    Generates reports in a custom output directory.
#>

[CmdletBinding()]
param(
    [string]$OutputPath
)

# Variables

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path -Path $PSScriptRoot -ChildPath 'reports'
}

$CsvFileName  = 'InventoryReport.csv'
$HtmlFileName = 'InventoryReport.html'

if (-not (Test-Path -Path $OutputPath)) {
    try {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }
    catch {
        Write-Error "Unable to create output directory '$OutputPath'. $_"
        exit 1
    }
}

$CsvPath  = Join-Path -Path $OutputPath -ChildPath $CsvFileName
$HtmlPath = Join-Path -Path $OutputPath -ChildPath $HtmlFileName

# System Information

try {
    $OperatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem
    $ComputerSystem  = Get-CimInstance -ClassName Win32_ComputerSystem
    $Bios            = Get-CimInstance -ClassName Win32_BIOS
    $Processor       = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
}
catch {
    Write-Error "Unable to retrieve system information. $_"
    exit 1
}

$LastBoot = $OperatingSystem.LastBootUpTime
$Uptime   = (Get-Date) - $LastBoot
$UptimeFormatted = '{0} days, {1} hours, {2} minutes' -f $Uptime.Days, $Uptime.Hours, $Uptime.Minutes

$SystemInventory = [PSCustomObject]@{
    ComputerName    = $env:COMPUTERNAME
    OperatingSystem = $OperatingSystem.Caption
    OSVersion       = $OperatingSystem.Version
    Manufacturer    = $ComputerSystem.Manufacturer
    Model           = $ComputerSystem.Model
    TotalRAMGB      = [math]::Round($ComputerSystem.TotalPhysicalMemory / 1GB, 2)
    FreeRAMGB       = [math]::Round($OperatingSystem.FreePhysicalMemory / 1MB, 2)
    BIOSVersion     = $Bios.SMBIOSBIOSVersion
    SerialNumber    = $Bios.SerialNumber
    CPUName         = $Processor.Name
    SystemUptime    = $UptimeFormatted
}

# Disk Information

try {
    $DiskInventory = Get-Volume |
        Where-Object { $_.DriveLetter -and $_.Size -gt 0 } |
        ForEach-Object {
            [PSCustomObject]@{
                ComputerName = $env:COMPUTERNAME
                DriveLetter  = $_.DriveLetter
                TotalSizeGB  = [math]::Round($_.Size / 1GB, 2)
                FreeSpaceGB  = [math]::Round($_.SizeRemaining / 1GB, 2)
                FreePercent  = [math]::Round(($_.SizeRemaining / $_.Size) * 100, 1)
            }
        }
}
catch {
    Write-Error "Unable to retrieve disk information. $_"
    exit 1
}

# Export Reports

try {
    $CsvExport = @(
        [PSCustomObject]@{
            RecordType      = 'System'
            ComputerName    = $SystemInventory.ComputerName
            OperatingSystem = $SystemInventory.OperatingSystem
            OSVersion       = $SystemInventory.OSVersion
            Manufacturer    = $SystemInventory.Manufacturer
            Model           = $SystemInventory.Model
            TotalRAMGB      = $SystemInventory.TotalRAMGB
            FreeRAMGB       = $SystemInventory.FreeRAMGB
            BIOSVersion     = $SystemInventory.BIOSVersion
            SerialNumber    = $SystemInventory.SerialNumber
            CPUName         = $SystemInventory.CPUName
            SystemUptime    = $SystemInventory.SystemUptime
            DriveLetter     = ''
            TotalSizeGB     = ''
            FreeSpaceGB     = ''
            FreePercent     = ''
        }
    )

    foreach ($Disk in $DiskInventory) {
        $CsvExport += [PSCustomObject]@{
            RecordType      = 'Disk'
            ComputerName    = $Disk.ComputerName
            OperatingSystem = ''
            OSVersion       = ''
            Manufacturer    = ''
            Model           = ''
            TotalRAMGB      = ''
            FreeRAMGB       = ''
            BIOSVersion     = ''
            SerialNumber    = ''
            CPUName         = ''
            SystemUptime    = ''
            DriveLetter     = $Disk.DriveLetter
            TotalSizeGB     = $Disk.TotalSizeGB
            FreeSpaceGB     = $Disk.FreeSpaceGB
            FreePercent     = $Disk.FreePercent
        }
    }

    $CsvExport | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8

    $ReportDate   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $SystemHtml   = $SystemInventory | ConvertTo-Html -Fragment -Property *
    $DiskHtml     = $DiskInventory | ConvertTo-Html -Fragment -Property DriveLetter, TotalSizeGB, FreeSpaceGB, FreePercent

    $HtmlReport = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Server Inventory Report - $($SystemInventory.ComputerName)</title>
    <style>
        body { font-family: Segoe UI, Arial, sans-serif; margin: 40px; color: #333; background-color: #f5f5f5; }
        .container { max-width: 960px; margin: 0 auto; background: #fff; padding: 30px; border-radius: 8px; box-shadow: 0 2px 8px rgba(0,0,0,0.1); }
        h1 { color: #0078d4; border-bottom: 2px solid #0078d4; padding-bottom: 10px; }
        h2 { color: #444; margin-top: 30px; }
        .meta { color: #666; font-size: 0.9em; margin-bottom: 20px; }
        table { border-collapse: collapse; width: 100%; margin-top: 10px; }
        th { background-color: #0078d4; color: #fff; text-align: left; padding: 10px; }
        td { padding: 8px 10px; border-bottom: 1px solid #ddd; }
        tr:nth-child(even) { background-color: #f9f9f9; }
        .footer { margin-top: 30px; font-size: 0.85em; color: #888; text-align: center; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Server Inventory Report</h1>
        <p class="meta">Computer: <strong>$($SystemInventory.ComputerName)</strong> | Generated: $ReportDate</p>
        <h2>System Information</h2>
        $SystemHtml
        <h2>Disk Information</h2>
        $DiskHtml
        <p class="footer">PowerShell Server Inventory Report v1.0</p>
    </div>
</body>
</html>
"@

    $HtmlReport | Out-File -FilePath $HtmlPath -Encoding UTF8
}
catch {
    Write-Error "Unable to export inventory reports. $_"
    exit 1
}

# Console Output

Write-Host '==============================='
Write-Host ' Server Inventory Report'
Write-Host '==============================='
Write-Host ''
Write-Host 'System Information'
Write-Host '------------------'
$SystemInventory | Format-List
Write-Host 'Disk Information'
Write-Host '----------------'
$DiskInventory | Format-Table -AutoSize
Write-Host ''
Write-Host "CSV report saved to:  $CsvPath"
Write-Host "HTML report saved to: $HtmlPath"
