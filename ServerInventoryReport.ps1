#Requires -Version 5.1

<#
.SYNOPSIS
    Generates a multi-server inventory report and exports results to CSV, HTML, and JSON.

.DESCRIPTION
    PowerShell Server Inventory Report v1.3
    Reads server names from servers.txt and collects system, hardware, BIOS,
    CPU, uptime, and disk information from each target using CIM/WMI.
    Exports a combined inventory report to CSV, a dashboard-style HTML report,
    and a JSON report for InfraOps Dashboard integration.

.PARAMETER OutputPath
    Directory where InventoryReport.csv, InventoryReport.html, and InventoryReport.json will be saved.
    Defaults to the reports folder in the script directory.

.PARAMETER ServerListFile
    Path to the server list file. Defaults to servers.txt in the script directory.

.EXAMPLE
    .\ServerInventoryReport.ps1
    Generates reports for all servers listed in servers.txt.

.EXAMPLE
    .\ServerInventoryReport.ps1 -OutputPath 'C:\Reports'
    Generates reports in a custom output directory.

.EXAMPLE
    .\ServerInventoryReport.ps1 -ServerListFile '.\my-servers.txt'
    Uses a custom server list file.
#>

[CmdletBinding()]
param(
    [string]$OutputPath,
    [string]$ServerListFile
)

# Variables

$ErrorActionPreference = 'Stop'
$ScriptVersion    = 'v1.3'
$ReportScriptName = 'ServerInventoryReport.ps1'

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path -Path $PSScriptRoot -ChildPath 'reports'
}

if ([string]::IsNullOrWhiteSpace($ServerListFile)) {
    $ServerListFile = Join-Path -Path $PSScriptRoot -ChildPath 'servers.txt'
}

$CsvFileName  = 'InventoryReport.csv'
$HtmlFileName = 'InventoryReport.html'
$JsonFileName = 'InventoryReport.json'

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
$JsonPath = Join-Path -Path $OutputPath -ChildPath $JsonFileName

# Functions

function Get-ServerList {
    <#
    .SYNOPSIS
        Reads server names from the server list file.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path)) {
        throw "Server list file not found: $Path"
    }

    $Servers = Get-Content -Path $Path |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') }

    if (-not $Servers) {
        throw "No servers found in server list file: $Path"
    }

    return $Servers
}

function Get-DiskHealthStatus {
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

function Get-ServerHealthStatus {
    <#
    .SYNOPSIS
        Determines overall server health based on disk statuses.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$DiskStatuses
    )

    if ($DiskStatuses -contains 'Critical') {
        return 'Critical'
    }
    elseif ($DiskStatuses -contains 'Warning') {
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
        'Healthy'     { return 'status-healthy' }
        'Warning'     { return 'status-warning' }
        'Critical'    { return 'status-critical' }
        'Unreachable' { return 'status-unreachable' }
        default       { return '' }
    }
}

function Get-UptimeDisplay {
    param(
        [Parameter(Mandatory)]
        [datetime]$LastBootUpTime
    )

    $Uptime = (Get-Date) - $LastBootUpTime
    $Detailed = '{0} days, {1} hours, {2} minutes' -f $Uptime.Days, $Uptime.Hours, $Uptime.Minutes

    if ($Uptime.Days -gt 0) {
        $Short = "$($Uptime.Days) Day$(if ($Uptime.Days -ne 1) { 's' })"
    }
    else {
        $Short = "$($Uptime.Hours) Hour$(if ($Uptime.Hours -ne 1) { 's' })"
    }

    return [PSCustomObject]@{
        Detailed = $Detailed
        Short    = $Short
    }
}

function Get-LocalDiskInventory {
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName
    )

    return Get-Volume |
        Where-Object { $_.DriveLetter -and $_.Size -gt 0 } |
        ForEach-Object {
            $FreePercent = [math]::Round(($_.SizeRemaining / $_.Size) * 100, 1)

            [PSCustomObject]@{
                ComputerName = $ComputerName
                DriveLetter  = $_.DriveLetter
                TotalSizeGB  = [math]::Round($_.Size / 1GB, 2)
                FreeSpaceGB  = [math]::Round($_.SizeRemaining / 1GB, 2)
                FreePercent  = $FreePercent
                Status       = Get-DiskHealthStatus -FreePercent $FreePercent
            }
        }
}

function Get-RemoteDiskInventory {
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName
    )

    return Get-CimInstance -ClassName Win32_LogicalDisk -ComputerName $ComputerName -Filter 'DriveType=3' |
        Where-Object { $_.Size -gt 0 } |
        ForEach-Object {
            $FreePercent = [math]::Round(($_.FreeSpace / $_.Size) * 100, 1)

            [PSCustomObject]@{
                ComputerName = $ComputerName
                DriveLetter  = $_.DeviceID.TrimEnd(':')
                TotalSizeGB  = [math]::Round($_.Size / 1GB, 2)
                FreeSpaceGB  = [math]::Round($_.FreeSpace / 1GB, 2)
                FreePercent  = $FreePercent
                Status       = Get-DiskHealthStatus -FreePercent $FreePercent
            }
        }
}

function Get-ServerInventory {
    <#
    .SYNOPSIS
        Collects inventory for a single server using CIM and local disk cmdlets.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ServerName
    )

    $IsLocal = $ServerName -in @('localhost', '.', '127.0.0.1') -or
        $ServerName.Equals($env:COMPUTERNAME, [System.StringComparison]::OrdinalIgnoreCase)

    $CimParams = @{}
    if (-not $IsLocal) {
        $CimParams['ComputerName'] = $ServerName
    }

    try {
        $OperatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem @CimParams -ErrorAction Stop
        $ComputerSystem  = Get-CimInstance -ClassName Win32_ComputerSystem @CimParams -ErrorAction Stop
        $Bios            = Get-CimInstance -ClassName Win32_BIOS @CimParams -ErrorAction Stop
        $Processor       = Get-CimInstance -ClassName Win32_Processor @CimParams -ErrorAction Stop | Select-Object -First 1

        $Uptime = Get-UptimeDisplay -LastBootUpTime $OperatingSystem.LastBootUpTime

        $SystemInventory = [PSCustomObject]@{
            ServerName      = $ServerName
            ComputerName    = $ComputerSystem.Name
            OperatingSystem = $OperatingSystem.Caption
            OSVersion       = $OperatingSystem.Version
            Manufacturer    = $ComputerSystem.Manufacturer
            Model           = $ComputerSystem.Model
            TotalRAMGB      = [math]::Round($ComputerSystem.TotalPhysicalMemory / 1GB, 2)
            FreeRAMGB       = [math]::Round($OperatingSystem.FreePhysicalMemory / 1MB, 2)
            BIOSVersion     = $Bios.SMBIOSBIOSVersion
            SerialNumber    = $Bios.SerialNumber
            CPUName         = $Processor.Name
            SystemUptime    = $Uptime.Detailed
            UptimeShort     = $Uptime.Short
            ServerStatus    = 'Healthy'
            Reachable       = $true
        }

        if ($IsLocal) {
            $DiskInventory = @(Get-LocalDiskInventory -ComputerName $SystemInventory.ComputerName)
        }
        else {
            $DiskInventory = @(Get-RemoteDiskInventory -ComputerName $ServerName)
        }

        $SystemInventory.ServerStatus = Get-ServerHealthStatus -DiskStatuses @($DiskInventory.Status)

        return [PSCustomObject]@{
            System = $SystemInventory
            Disks  = $DiskInventory
        }
    }
    catch {
        return [PSCustomObject]@{
            System = [PSCustomObject]@{
                ServerName      = $ServerName
                ComputerName    = $ServerName
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
                UptimeShort     = ''
                ServerStatus    = 'Unreachable'
                Reachable       = $false
                ErrorMessage    = $_.Exception.Message
            }
            Disks = @()
        }
    }
}

function Get-HtmlServerStatusTable {
    param(
        [Parameter(Mandatory)]
        [array]$Servers
    )

    $HtmlRows = foreach ($Server in $Servers) {
        $StatusClass = Get-StatusCssClass -Status $Server.ServerStatus
        @"
        <tr>
            <td>$($Server.ComputerName)</td>
            <td>$($Server.OperatingSystem)</td>
            <td>$($Server.OSVersion)</td>
            <td>$($Server.Manufacturer)</td>
            <td>$($Server.Model)</td>
            <td>$($Server.CPUName)</td>
            <td>$($Server.TotalRAMGB)</td>
            <td>$($Server.FreeRAMGB)</td>
            <td>$($Server.BIOSVersion)</td>
            <td>$($Server.SerialNumber)</td>
            <td>$($Server.UptimeShort)</td>
            <td><span class="status-badge $StatusClass">$($Server.ServerStatus)</span></td>
        </tr>
"@
    }

    return @"
<table class="data-table server-table">
    <thead>
        <tr>
            <th>Computer</th>
            <th>Operating System</th>
            <th>Version</th>
            <th>Manufacturer</th>
            <th>Model</th>
            <th>CPU</th>
            <th>Total RAM (GB)</th>
            <th>Free RAM (GB)</th>
            <th>BIOS</th>
            <th>Serial</th>
            <th>Uptime</th>
            <th>Status</th>
        </tr>
    </thead>
    <tbody>
        $($HtmlRows -join "`n")
    </tbody>
</table>
"@
}

function Get-HtmlDiskDetailsTable {
    param(
        [Parameter(Mandatory)]
        [array]$Disks
    )

    if (-not $Disks) {
        return '<p class="no-data">No disk information available.</p>'
    }

    $HtmlRows = foreach ($Disk in $Disks) {
        $StatusClass = Get-StatusCssClass -Status $Disk.Status
        @"
        <tr>
            <td>$($Disk.ComputerName)</td>
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
            <th>Computer</th>
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

function Export-InventoryJson {
    <#
    .SYNOPSIS
        Builds and exports the inventory report as JSON for dashboard integration.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Version,

        [Parameter(Mandatory)]
        [string]$GeneratedBy,

        [Parameter(Mandatory)]
        [object]$Summary,

        [Parameter(Mandatory)]
        [array]$Servers,

        [Parameter(Mandatory)]
        [array]$Disks
    )

    $ReachableServers = @($Servers | Where-Object { $_.Reachable })
    $FailedServers    = @($Servers | Where-Object { -not $_.Reachable })

    $JsonReport = [ordered]@{
        reportVersion = $Version
        generatedAt   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
        generatedBy   = $GeneratedBy
        serverSummary = [ordered]@{
            totalServers    = $Summary.TotalServers
            healthyServers  = $Summary.HealthyServers
            warningServers  = $Summary.WarningServers
            criticalServers = $Summary.CriticalServers
            failedServers   = $Summary.FailedServers
            totalDrives     = $Summary.TotalDrives
            healthyDrives   = $Summary.HealthyDrives
            warningDrives   = $Summary.WarningDrives
            criticalDrives  = $Summary.CriticalDrives
        }
        servers = @(
            foreach ($Server in $ReachableServers) {
                [ordered]@{
                    computerName    = $Server.ComputerName
                    operatingSystem = $Server.OperatingSystem
                    osVersion       = $Server.OSVersion
                    manufacturer    = $Server.Manufacturer
                    model           = $Server.Model
                    totalRamGB      = [double]$Server.TotalRAMGB
                    freeRamGB       = [double]$Server.FreeRAMGB
                    biosVersion     = $Server.BIOSVersion
                    serialNumber    = $Server.SerialNumber
                    cpuName         = $Server.CPUName
                    systemUptime    = $Server.UptimeShort
                    serverStatus    = $Server.ServerStatus
                }
            }
        )
        disks = @(
            foreach ($Disk in $Disks) {
                [ordered]@{
                    computerName = $Disk.ComputerName
                    driveLetter  = [string]$Disk.DriveLetter
                    totalSizeGB  = [double]$Disk.TotalSizeGB
                    freeSpaceGB  = [double]$Disk.FreeSpaceGB
                    freePercent  = [double]$Disk.FreePercent
                    status       = $Disk.Status
                }
            }
        )
        failedServers = @(
            foreach ($Server in $FailedServers) {
                [ordered]@{
                    serverName    = $Server.ServerName
                    computerName  = $Server.ComputerName
                    serverStatus  = $Server.ServerStatus
                    errorMessage  = $Server.ErrorMessage
                }
            }
        )
    }

    $JsonReport | ConvertTo-Json -Depth 5 | Out-File -FilePath $Path -Encoding UTF8
}

function Write-DiskConsoleTable {
    <#
    .SYNOPSIS
        Writes disk inventory to the console in a readable table format.
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Disks
    )

    if (-not $Disks) {
        return
    }

    $Disks |
        Select-Object `
            @{Name = 'ComputerName'; Expression = { $_.ComputerName } }, `
            @{Name = 'DriveLetter';  Expression = { $_.DriveLetter } }, `
            @{Name = 'TotalSizeGB';  Expression = { $_.TotalSizeGB } }, `
            @{Name = 'FreeSpaceGB';  Expression = { $_.FreeSpaceGB } }, `
            @{Name = 'FreePercent';  Expression = { $_.FreePercent } }, `
            @{Name = 'Status';       Expression = { $_.Status } } |
        Format-Table -Property ComputerName, DriveLetter, TotalSizeGB, FreeSpaceGB, FreePercent, Status -AutoSize |
        Out-String -Width 250 |
        ForEach-Object { Write-Host $_ }
}

function Get-HtmlStyles {
    return @'
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
            max-width: 1200px;
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
            grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
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
        .summary-card.failed .value { color: #6b7280; }
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
        .data-table th {
            background-color: #0078d4;
            color: #ffffff;
            text-align: left;
            padding: 12px 14px;
            font-weight: 600;
            white-space: nowrap;
        }
        .data-table td {
            padding: 11px 14px;
            border-bottom: 1px solid #e5e7eb;
            vertical-align: top;
        }
        .data-table tr:nth-child(even) {
            background-color: #f9fafb;
        }
        .server-table {
            display: block;
            overflow-x: auto;
            white-space: nowrap;
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
        .status-unreachable {
            background-color: #f3f4f6;
            color: #6b7280;
        }
        .no-data {
            color: #6b7280;
            font-style: italic;
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
'@
}

# Read Server List

try {
    $ServerNames = Get-ServerList -Path $ServerListFile
}
catch {
    Write-Error $_
    exit 1
}

# Collect Inventory

$InventoryResults = foreach ($ServerName in $ServerNames) {
    Write-Verbose "Collecting inventory for: $ServerName"
    Get-ServerInventory -ServerName $ServerName
}

$AllServers = @($InventoryResults | ForEach-Object { $_.System })
$AllDisks   = @($InventoryResults | ForEach-Object { $_.Disks })

# Dashboard Summary

$ServerSummary = [PSCustomObject]@{
    TotalServers    = $AllServers.Count
    HealthyServers  = @($AllServers | Where-Object ServerStatus -eq 'Healthy').Count
    WarningServers  = @($AllServers | Where-Object ServerStatus -eq 'Warning').Count
    CriticalServers = @($AllServers | Where-Object ServerStatus -eq 'Critical').Count
    FailedServers   = @($AllServers | Where-Object ServerStatus -eq 'Unreachable').Count
    TotalDrives     = $AllDisks.Count
    HealthyDrives   = @($AllDisks | Where-Object Status -eq 'Healthy').Count
    WarningDrives   = @($AllDisks | Where-Object Status -eq 'Warning').Count
    CriticalDrives  = @($AllDisks | Where-Object Status -eq 'Critical').Count
}

# Export Reports

try {
    $CsvExport = @()

    foreach ($Server in $AllServers) {
        $CsvExport += [PSCustomObject]@{
            RecordType      = 'Server'
            ServerName      = $Server.ServerName
            ComputerName    = $Server.ComputerName
            OperatingSystem = $Server.OperatingSystem
            OSVersion       = $Server.OSVersion
            Manufacturer    = $Server.Manufacturer
            Model           = $Server.Model
            TotalRAMGB      = $Server.TotalRAMGB
            FreeRAMGB       = $Server.FreeRAMGB
            BIOSVersion     = $Server.BIOSVersion
            SerialNumber    = $Server.SerialNumber
            CPUName         = $Server.CPUName
            SystemUptime    = $Server.SystemUptime
            DriveLetter     = ''
            TotalSizeGB     = ''
            FreeSpaceGB     = ''
            FreePercent     = ''
            Status          = $Server.ServerStatus
        }
    }

    foreach ($Disk in $AllDisks) {
        $CsvExport += [PSCustomObject]@{
            RecordType      = 'Disk'
            ServerName      = $Disk.ComputerName
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

    $ReportDate      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $ReportDateShort = Get-Date -Format 'yyyy-MM-dd'
    $CurrentUser     = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $ServerHtml      = Get-HtmlServerStatusTable -Servers $AllServers
    $DiskHtml        = Get-HtmlDiskDetailsTable -Disks $AllDisks

    $HtmlReport = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Multi-Server Inventory Report</title>
    <style>
$(Get-HtmlStyles)
    </style>
</head>
<body>
    <div class="container">
        <h1>Multi-Server Inventory Report</h1>
        <p class="subtitle">Automated inventory and health dashboard for $($ServerSummary.TotalServers) server(s)</p>

        <div class="summary-panel">
            <h2>Server Summary</h2>
            <div class="summary-meta">
                <strong>Generated:</strong> $ReportDateShort &nbsp;|&nbsp;
                <strong>Servers Scanned:</strong> $($ServerSummary.TotalServers)
            </div>
            <div class="summary-grid">
                <div class="summary-card">
                    <div class="label">Total Servers</div>
                    <div class="value">$($ServerSummary.TotalServers)</div>
                </div>
                <div class="summary-card healthy">
                    <div class="label">Healthy Servers</div>
                    <div class="value">$($ServerSummary.HealthyServers)</div>
                </div>
                <div class="summary-card warning">
                    <div class="label">Warning Servers</div>
                    <div class="value">$($ServerSummary.WarningServers)</div>
                </div>
                <div class="summary-card critical">
                    <div class="label">Critical Servers</div>
                    <div class="value">$($ServerSummary.CriticalServers)</div>
                </div>
                <div class="summary-card failed">
                    <div class="label">Failed Servers</div>
                    <div class="value">$($ServerSummary.FailedServers)</div>
                </div>
            </div>
            <div class="summary-meta">
                <strong>Disk Summary:</strong>
                $($ServerSummary.TotalDrives) drives |
                $($ServerSummary.HealthyDrives) healthy |
                $($ServerSummary.WarningDrives) warning |
                $($ServerSummary.CriticalDrives) critical
            </div>
        </div>

        <h2>Server Status</h2>
        $ServerHtml

        <h2>Disk Details</h2>
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

    # JSON Report

    Export-InventoryJson -Path $JsonPath `
        -Version $ScriptVersion `
        -GeneratedBy $ReportScriptName `
        -Summary $ServerSummary `
        -Servers $AllServers `
        -Disks $AllDisks
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
Write-Host 'Server Summary'
Write-Host '--------------'
$ServerSummary | Format-List
Write-Host ''

foreach ($Result in $InventoryResults) {
    $Server = $Result.System

    Write-Host "Server: $($Server.ComputerName) [$($Server.ServerStatus)]"
    Write-Host '----------------------------------------'

    if ($Server.Reachable) {
        $Server | Select-Object ComputerName, OperatingSystem, OSVersion, Manufacturer, Model,
            TotalRAMGB, FreeRAMGB, BIOSVersion, SerialNumber, CPUName, SystemUptime |
            Format-List

        if ($Result.Disks) {
            Write-Host 'Disk Information'
            Write-DiskConsoleTable -Disks $Result.Disks
        }
    }
    else {
        Write-Warning "Unable to reach server '$($Server.ServerName)'. Status: Unreachable"
        if ($Server.ErrorMessage) {
            Write-Host "  Error: $($Server.ErrorMessage)"
        }
    }

    Write-Host ''
}

Write-Host "CSV report saved to:  $CsvPath"
Write-Host "HTML report saved to: $HtmlPath"
Write-Host "JSON report saved to: $JsonPath"
