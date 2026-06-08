#Requires -Version 5.1

<#
.SYNOPSIS
    Generates a server inventory report and exports results to CSV and HTML.

.DESCRIPTION
    PowerShell Server Inventory Report v1.1
    Collects system, hardware, BIOS, CPU, uptime, and disk information from
    the local computer using CIM and Get-Volume. Exports a combined inventory
    report to CSV and a formatted HTML report with disk health monitoring,
    summary dashboard, and color-coded status indicators.

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
$ScriptVersion   = 'v1.1'
$ReportScriptName = 'ServerInventoryReport.ps1'

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

# Functions

function Get-DiskHealthStatus {
    <#
    .SYNOPSIS
        Returns disk health status based on free space percentage.
    #>
    param(
        [Parameter(Mandatory)]
        [double]$FreePercent
    )

    if ($FreePercent -lt 10) {
        return 'Critical'
    }
    elseif ($FreePercent -lt 20) {
        return 'Warning'
    }
    else {
        return 'Healthy'
    }
}

function Get-StatusCssClass {
    param(
        [Parameter(Mandatory)]
        [string]$Status
    )

    switch ($Status) {
        'Healthy'  { return 'status-healthy' }
        'Warning'  { return 'status-warning' }
        'Critical' { return 'status-critical' }
        default    { return '' }
    }
}

function Get-HtmlSystemInfoTable {
    param(
        [Parameter(Mandatory)]
        [array]$Rows
    )

    $HtmlRows = foreach ($Row in $Rows) {
        "<tr><td class='property'>$($Row.Property)</td><td class='value'>$($Row.Value)</td></tr>"
    }

    return @"
<table class="info-table">
    <thead>
        <tr><th>Property</th><th>Value</th></tr>
    </thead>
    <tbody>
        $($HtmlRows -join "`n        ")
    </tbody>
</table>
"@
}

function Get-HtmlDiskTable {
    param(
        [Parameter(Mandatory)]
        [array]$Disks
    )

    $HtmlRows = foreach ($Disk in $Disks) {
        $StatusClass = Get-StatusCssClass -Status $Disk.Status
        @"
        <tr>
            <td>$($Disk.DriveLetter)</td>
            <td>$($Disk.TotalSizeGB) GB</td>
            <td>$($Disk.FreeSpaceGB) GB</td>
            <td>$($Disk.FreePercent)%</td>
            <td><span class="status-badge $StatusClass">$($Disk.Status)</span></td>
        </tr>
"@
    }

    return @"
<table class="data-table">
    <thead>
        <tr>
            <th>Drive</th>
            <th>Total Size</th>
            <th>Free Space</th>
            <th>Free %</th>
            <th>Status</th>
        </tr>
    </thead>
    <tbody>
        $($HtmlRows -join "`n")
    </tbody>
</table>
"@
}

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

if ($Uptime.Days -gt 0) {
    $UptimeHtmlDisplay = "$($Uptime.Days) Day$(if ($Uptime.Days -ne 1) { 's' })"
}
else {
    $UptimeHtmlDisplay = "$($Uptime.Hours) Hour$(if ($Uptime.Hours -ne 1) { 's' })"
}

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
            $FreePercent = [math]::Round(($_.SizeRemaining / $_.Size) * 100, 1)

            [PSCustomObject]@{
                ComputerName = $env:COMPUTERNAME
                DriveLetter  = $_.DriveLetter
                TotalSizeGB  = [math]::Round($_.Size / 1GB, 2)
                FreeSpaceGB  = [math]::Round($_.SizeRemaining / 1GB, 2)
                FreePercent  = $FreePercent
                Status       = Get-DiskHealthStatus -FreePercent $FreePercent
            }
        }
}
catch {
    Write-Error "Unable to retrieve disk information. $_"
    exit 1
}

# Disk Health Summary

$DiskSummary = [PSCustomObject]@{
    TotalDrives    = $DiskInventory.Count
    HealthyDrives  = @($DiskInventory | Where-Object Status -eq 'Healthy').Count
    WarningDrives  = @($DiskInventory | Where-Object Status -eq 'Warning').Count
    CriticalDrives = @($DiskInventory | Where-Object Status -eq 'Critical').Count
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
            Status          = ''
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
            Status          = $Disk.Status
        }
    }

    $CsvExport | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8

    # HTML Report

    $ReportDate  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $ReportDateShort = Get-Date -Format 'yyyy-MM-dd'
    $CurrentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

    $SystemInfoRows = @(
        @{ Property = 'Computer Name';    Value = $SystemInventory.ComputerName }
        @{ Property = 'Operating System'; Value = $SystemInventory.OperatingSystem }
        @{ Property = 'Version';          Value = $SystemInventory.OSVersion }
        @{ Property = 'Manufacturer';     Value = $SystemInventory.Manufacturer }
        @{ Property = 'Model';            Value = $SystemInventory.Model }
        @{ Property = 'CPU';              Value = $SystemInventory.CPUName }
        @{ Property = 'Total RAM';        Value = "$($SystemInventory.TotalRAMGB) GB" }
        @{ Property = 'Free RAM';         Value = "$($SystemInventory.FreeRAMGB) GB" }
        @{ Property = 'BIOS Version';     Value = $SystemInventory.BIOSVersion }
        @{ Property = 'Serial Number';    Value = $SystemInventory.SerialNumber }
        @{ Property = 'Uptime';           Value = $UptimeHtmlDisplay }
    )

    $SystemHtml = Get-HtmlSystemInfoTable -Rows $SystemInfoRows
    $DiskHtml   = Get-HtmlDiskTable -Disks $DiskInventory

    $HtmlReport = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Server Inventory Report - $($SystemInventory.ComputerName)</title>
    <style>
        * { box-sizing: border-box; }
        body {
            font-family: 'Segoe UI', Tahoma, Arial, sans-serif;
            margin: 0;
            padding: 32px 20px;
            color: #1a1a1a;
            background: linear-gradient(135deg, #eef2f7 0%, #dfe6ef 100%);
            line-height: 1.5;
        }
        .container {
            max-width: 980px;
            margin: 0 auto;
            background: #ffffff;
            padding: 36px;
            border-radius: 12px;
            box-shadow: 0 8px 24px rgba(0, 0, 0, 0.08);
        }
        h1 {
            margin: 0 0 8px 0;
            color: #0f548c;
            font-size: 1.9rem;
        }
        h2 {
            color: #2f3b4a;
            margin: 32px 0 14px 0;
            font-size: 1.2rem;
            border-left: 4px solid #0078d4;
            padding-left: 12px;
        }
        .subtitle {
            color: #5f6b7a;
            margin-bottom: 24px;
        }
        .summary-panel {
            background: #f7f9fc;
            border: 1px solid #dbe3ee;
            border-radius: 10px;
            padding: 24px;
            margin-bottom: 28px;
        }
        .summary-panel h2 {
            margin-top: 0;
            border-left: none;
            padding-left: 0;
        }
        .summary-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
            gap: 16px;
            margin-top: 16px;
        }
        .summary-card {
            background: #ffffff;
            border: 1px solid #e3e8ef;
            border-radius: 8px;
            padding: 16px;
            text-align: center;
        }
        .summary-card .label {
            font-size: 0.85rem;
            color: #667085;
            margin-bottom: 6px;
        }
        .summary-card .value {
            font-size: 1.6rem;
            font-weight: 700;
            color: #1f2937;
        }
        .summary-card.healthy .value { color: #107c10; }
        .summary-card.warning .value { color: #d97706; }
        .summary-card.critical .value { color: #c50f1f; }
        .summary-meta {
            margin-top: 16px;
            color: #4b5563;
            font-size: 0.95rem;
        }
        table {
            border-collapse: collapse;
            width: 100%;
            margin-top: 8px;
        }
        .info-table th,
        .data-table th {
            background-color: #0078d4;
            color: #ffffff;
            text-align: left;
            padding: 12px 14px;
            font-weight: 600;
        }
        .info-table td,
        .data-table td {
            padding: 11px 14px;
            border-bottom: 1px solid #e5e7eb;
            vertical-align: top;
        }
        .info-table tr:nth-child(even),
        .data-table tr:nth-child(even) {
            background-color: #f9fafb;
        }
        .info-table td.property {
            width: 35%;
            font-weight: 600;
            color: #374151;
        }
        .info-table td.value {
            color: #111827;
        }
        .status-badge {
            display: inline-block;
            padding: 4px 12px;
            border-radius: 999px;
            font-size: 0.85rem;
            font-weight: 700;
            letter-spacing: 0.02em;
        }
        .status-healthy {
            background-color: #dff6dd;
            color: #107c10;
        }
        .status-warning {
            background-color: #fff4ce;
            color: #d97706;
        }
        .status-critical {
            background-color: #fde7e9;
            color: #c50f1f;
        }
        .footer {
            margin-top: 36px;
            padding-top: 18px;
            border-top: 1px solid #e5e7eb;
            font-size: 0.88rem;
            color: #6b7280;
            text-align: center;
        }
        .footer p {
            margin: 4px 0;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Server Inventory Report</h1>
        <p class="subtitle">Automated inventory and disk health report for $($SystemInventory.ComputerName)</p>

        <div class="summary-panel">
            <h2>Server Inventory Summary</h2>
            <div class="summary-meta">
                <strong>Computer Name:</strong> $($SystemInventory.ComputerName)<br>
                <strong>Generated:</strong> $ReportDateShort
            </div>
            <div class="summary-grid">
                <div class="summary-card">
                    <div class="label">Total Drives</div>
                    <div class="value">$($DiskSummary.TotalDrives)</div>
                </div>
                <div class="summary-card healthy">
                    <div class="label">Healthy Drives</div>
                    <div class="value">$($DiskSummary.HealthyDrives)</div>
                </div>
                <div class="summary-card warning">
                    <div class="label">Warning Drives</div>
                    <div class="value">$($DiskSummary.WarningDrives)</div>
                </div>
                <div class="summary-card critical">
                    <div class="label">Critical Drives</div>
                    <div class="value">$($DiskSummary.CriticalDrives)</div>
                </div>
            </div>
        </div>

        <h2>System Information</h2>
        $SystemHtml

        <h2>Disk Information</h2>
        $DiskHtml

        <div class="footer">
            <p><strong>Generated By:</strong> $ReportScriptName</p>
            <p><strong>Current User:</strong> $CurrentUser</p>
            <p><strong>Report Version:</strong> $ScriptVersion</p>
            <p>Generated on $ReportDate</p>
        </div>
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
