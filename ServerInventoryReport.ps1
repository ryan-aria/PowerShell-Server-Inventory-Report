#Requires -Version 5.1

<#
.SYNOPSIS
    Generates a multi-server inventory report and exports results to CSV, HTML, and JSON.

.DESCRIPTION
    PowerShell Server Inventory Report v1.6
    Reads server names from servers.txt and collects system, hardware, BIOS,
    CPU, uptime, disk, Windows service, installed software, and network
    configuration information from each target. Exports a combined inventory
    report to CSV, a dashboard-style HTML report, and a JSON report for
    InfraOps Dashboard integration.

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

.EXAMPLE
    .\ServerInventoryReport.ps1 -SoftwareFilter 'VMware'
    Filters software results in CSV, HTML, and JSON exports to VMware-related entries.

.EXAMPLE
    .\ServerInventoryReport.ps1 -NetworkFilter 'Wi-Fi'
    Filters network results in CSV, HTML, and JSON exports to matching adapters.

.PARAMETER SoftwareFilter
    Optional filter applied to exported software results. Matches display name or publisher.
    Inventory collection still runs for all software; filtering applies to exports only.

.PARAMETER NetworkFilter
    Optional filter applied to exported network results. Matches adapter name or description.
    Inventory collection still runs for all adapters; filtering applies to exports only.
#>

[CmdletBinding()]
param(
    [string]$OutputPath,
    [string]$ServerListFile,
    [string]$SoftwareFilter,
    [string]$NetworkFilter
)

# Variables

$ErrorActionPreference = 'Stop'
$ScriptVersion    = 'v1.6'
$ReportScriptName = 'ServerInventoryReport.ps1'

$SoftwareRegistryPaths = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

$RemoteSoftwareRegistryPaths = @(
    'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)

$SoftwareNoisePatterns = @(
    'Security Update'
    'Update for Microsoft'
    'Hotfix'
    'Language Pack'
)

$MonitoredServices = @(
    'WinRM'
    'W32Time'
    'EventLog'
    'LanmanServer'
    'LanmanWorkstation'
    'Spooler'
    'Dhcp'
    'Dnscache'
    'RemoteRegistry'
    'Schedule'
    'BITS'
)

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

function Get-ServiceHealthStatus {
    <#
    .SYNOPSIS
        Evaluates monitored service health based on status and start type.
    #>
    param(
        [Parameter(Mandatory)]
        [bool]$Found,

        [string]$Status,
        [string]$StartType
    )

    if (-not $Found) {
        return 'Unknown'
    }

    if ($Status -eq 'Running') {
        return 'Healthy'
    }

    $IsAutomatic = $StartType -in @('Automatic', 'Auto', 'AutomaticDelayedStart')
    $IsManual    = $StartType -in @('Manual', 'ManualTrigger')

    if ($Status -eq 'Stopped' -and $IsAutomatic) {
        return 'Critical'
    }

    if ($Status -eq 'Stopped' -and $IsManual) {
        return 'Warning'
    }

    return 'Healthy'
}

function Get-CombinedServerHealthStatus {
    <#
    .SYNOPSIS
        Determines overall server health from disk, service, and network health statuses.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$DiskStatuses,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ServiceHealthStatuses,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$NetworkHealthStatuses
    )

    $AllStatuses = @($DiskStatuses) + @($ServiceHealthStatuses) + @($NetworkHealthStatuses)

    if ($AllStatuses -contains 'Critical') {
        return 'Critical'
    }

    if ($AllStatuses -contains 'Warning') {
        return 'Warning'
    }

    return 'Healthy'
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
        'Unknown'     { return 'status-unknown' }
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

function Format-SoftwareInstallDate {
    param(
        [string]$InstallDate
    )

    if ([string]::IsNullOrWhiteSpace($InstallDate)) {
        return ''
    }

    if ($InstallDate -match '^\d{8}$') {
        return '{0}-{1}-{2}' -f $InstallDate.Substring(0, 4), $InstallDate.Substring(4, 2), $InstallDate.Substring(6, 2)
    }

    return $InstallDate
}

function Test-NoisySoftwareEntry {
    param(
        [Parameter(Mandatory)]
        [string]$DisplayName
    )

    foreach ($Pattern in $SoftwareNoisePatterns) {
        if ($DisplayName -like "*$Pattern*") {
            return $true
        }
    }

    if ($DisplayName -match '\bKB\d+') {
        return $true
    }

    return $false
}

function Get-CleanSoftwareInventory {
    <#
    .SYNOPSIS
        Returns meaningful installed applications by excluding noisy registry entries.
    #>
    param(
        [array]$Software
    )

    return @($Software | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.DisplayName) -and
            -not (Test-NoisySoftwareEntry -DisplayName $_.DisplayName)
        })
}

function Get-FilteredSoftwareInventory {
    param(
        [array]$Software,

        [string]$Filter
    )

    if ([string]::IsNullOrWhiteSpace($Filter)) {
        return $Software
    }

    return @($Software | Where-Object {
            $_.DisplayName -like "*$Filter*" -or
            ($_.Publisher -and $_.Publisher -like "*$Filter*")
        })
}

function Get-SoftwareSummary {
    param(
        [array]$Software
    )

    $TopPublishers = $Software |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.Publisher) } |
        Group-Object Publisher |
        Sort-Object Count -Descending |
        Select-Object -First 10 @{Name = 'Publisher'; Expression = { $_.Name } }, Count

    return [PSCustomObject]@{
        TotalSoftwarePackages = $Software.Count
        TopPublisher          = ($TopPublishers | Select-Object -First 1).Publisher
        TopPublishers         = $TopPublishers
    }
}

function Get-RegistryStringValueRemote {
    param(
        [Parameter(Mandatory)]
        $CimSession,

        [Parameter(Mandatory)]
        [uint32]$Hive,

        [Parameter(Mandatory)]
        [string]$KeyPath,

        [Parameter(Mandatory)]
        [string]$ValueName
    )

    $Result = Invoke-CimMethod -CimSession $CimSession -Namespace root/default -ClassName StdRegProv -MethodName GetStringValue -Arguments @{
        hDefKey     = $Hive
        sSubKeyName = $KeyPath
        sValueName  = $ValueName
    } -ErrorAction SilentlyContinue

    if ($Result -and $Result.ReturnValue -eq 0) {
        return $Result.sValue
    }

    return ''
}

function Get-RegistryDwordValueRemote {
    param(
        [Parameter(Mandatory)]
        $CimSession,

        [Parameter(Mandatory)]
        [uint32]$Hive,

        [Parameter(Mandatory)]
        [string]$KeyPath,

        [Parameter(Mandatory)]
        [string]$ValueName
    )

    $Result = Invoke-CimMethod -CimSession $CimSession -Namespace root/default -ClassName StdRegProv -MethodName GetDWORDValue -Arguments @{
        hDefKey     = $Hive
        sSubKeyName = $KeyPath
        sValueName  = $ValueName
    } -ErrorAction SilentlyContinue

    if ($Result -and $Result.ReturnValue -eq 0) {
        return [uint32]$Result.uValue
    }

    return $null
}

function Get-LocalSoftwareFromRegistry {
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName
    )

    $Software = foreach ($Path in $SoftwareRegistryPaths) {
        Get-ItemProperty -Path $Path -ErrorAction SilentlyContinue |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.DisplayName) } |
            ForEach-Object {
                $EstimatedSizeMB = if ($_.EstimatedSize) {
                    [math]::Round($_.EstimatedSize / 1024, 2)
                }
                else {
                    0
                }

                [PSCustomObject]@{
                    ComputerName    = $ComputerName
                    DisplayName     = $_.DisplayName
                    DisplayVersion  = $_.DisplayVersion
                    Publisher       = $_.Publisher
                    InstallDate     = Format-SoftwareInstallDate -InstallDate ([string]$_.InstallDate)
                    EstimatedSizeMB = $EstimatedSizeMB
                }
            }
    }

    return @($Software)
}

function Get-RemoteSoftwareFromRegistry {
    param(
        [Parameter(Mandatory)]
        [string]$ServerName,

        [Parameter(Mandatory)]
        [string]$ComputerName
    )

    $Hive      = [uint32]2147483650
    $Software  = @()
    $CimSession = $null

    try {
        $CimSession = New-CimSession -ComputerName $ServerName -ErrorAction Stop

        foreach ($RegPath in $RemoteSoftwareRegistryPaths) {
            $EnumResult = Invoke-CimMethod -CimSession $CimSession -Namespace root/default -ClassName StdRegProv -MethodName EnumKey -Arguments @{
                hDefKey     = $Hive
                sSubKeyName = $RegPath
            } -ErrorAction SilentlyContinue

            if (-not $EnumResult -or $EnumResult.ReturnValue -ne 0 -or -not $EnumResult.sNames) {
                continue
            }

            foreach ($SubKey in $EnumResult.sNames) {
                $KeyPath = "$RegPath\$SubKey"
                $DisplayName = Get-RegistryStringValueRemote -CimSession $CimSession -Hive $Hive -KeyPath $KeyPath -ValueName 'DisplayName'

                if ([string]::IsNullOrWhiteSpace($DisplayName)) {
                    continue
                }

                $EstimatedSize = Get-RegistryDwordValueRemote -CimSession $CimSession -Hive $Hive -KeyPath $KeyPath -ValueName 'EstimatedSize'
                $EstimatedSizeMB = if ($EstimatedSize) {
                    [math]::Round($EstimatedSize / 1024, 2)
                }
                else {
                    0
                }

                $Software += [PSCustomObject]@{
                    ComputerName    = $ComputerName
                    DisplayName     = $DisplayName
                    DisplayVersion  = Get-RegistryStringValueRemote -CimSession $CimSession -Hive $Hive -KeyPath $KeyPath -ValueName 'DisplayVersion'
                    Publisher       = Get-RegistryStringValueRemote -CimSession $CimSession -Hive $Hive -KeyPath $KeyPath -ValueName 'Publisher'
                    InstallDate     = Format-SoftwareInstallDate -InstallDate (Get-RegistryStringValueRemote -CimSession $CimSession -Hive $Hive -KeyPath $KeyPath -ValueName 'InstallDate')
                    EstimatedSizeMB = $EstimatedSizeMB
                }
            }
        }
    }
    finally {
        if ($CimSession) {
            Remove-CimSession -CimSession $CimSession -ErrorAction SilentlyContinue
        }
    }

    return $Software
}

function Get-SoftwareInventory {
    <#
    .SYNOPSIS
        Collects installed software inventory from registry paths.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ServerName,

        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [bool]$IsLocal
    )

    try {
        if ($IsLocal) {
            $RawSoftware = Get-LocalSoftwareFromRegistry -ComputerName $ComputerName
        }
        else {
            $RawSoftware = Get-RemoteSoftwareFromRegistry -ServerName $ServerName -ComputerName $ComputerName
        }

        return @(Get-CleanSoftwareInventory -Software $RawSoftware)
    }
    catch {
        Write-Verbose "Unable to collect software inventory for '$ServerName': $($_.Exception.Message)"
        return @()
    }
}

function Get-FirstNetworkValue {
    param(
        $Value
    )

    if ($null -eq $Value) {
        return ''
    }

    return [string](@($Value) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
}

function Format-NetworkMacAddress {
    param(
        [string]$MacAddress
    )

    if ([string]::IsNullOrWhiteSpace($MacAddress)) {
        return ''
    }

    $CleanMac = ($MacAddress -replace '[^0-9A-Fa-f]', '').ToUpper()

    if ($CleanMac.Length -ne 12) {
        return $MacAddress
    }

    return ($CleanMac -replace '(.{2})(?=.)', '$1-')
}

function Convert-PrefixLengthToSubnetMask {
    param(
        [int]$PrefixLength
    )

    if ($PrefixLength -le 0 -or $PrefixLength -gt 32) {
        return ''
    }

    $Mask = [uint32]0
    for ($i = 0; $i -lt $PrefixLength; $i++) {
        $Mask = $Mask -bor [uint32](1 -shl (31 - $i))
    }

    $Bytes = [BitConverter]::GetBytes($Mask)
    if ([BitConverter]::IsLittleEndian) {
        [array]::Reverse($Bytes)
    }

    return ([System.Net.IPAddress]$Bytes).ToString()
}

function Convert-LinkSpeedToMbps {
    param(
        $LinkSpeed
    )

    if ($null -eq $LinkSpeed) {
        return 0
    }

    if ($LinkSpeed -is [array]) {
        $LinkSpeed = ($LinkSpeed | Where-Object { $_ } | Select-Object -First 1)
    }

    if (-not $LinkSpeed -or ($LinkSpeed -is [int] -and $LinkSpeed -lt 0)) {
        return 0
    }

    try {
        return [math]::Round([uint64]$LinkSpeed / 1000000, 0)
    }
    catch {
        return 0
    }
}

function Get-AdapterNetworkHealthStatus {
    param(
        [Parameter(Mandatory)]
        [string]$Status
    )

    switch ($Status) {
        'Up' { return 'Healthy' }
        'Disconnected' { return 'Warning' }
        'Disabled' { return 'Warning' }
        default { return 'Warning' }
    }
}

function Get-ServerNetworkHealthStatus {
    <#
    .SYNOPSIS
        Determines server-level network health from adapter inventory.
    #>
    param(
        [array]$Networks
    )

    $ActiveWithIp = @($Networks | Where-Object {
            $_.Status -eq 'Up' -and -not [string]::IsNullOrWhiteSpace($_.IPAddress)
        })

    if (-not $ActiveWithIp) {
        return 'Critical'
    }

    if (@($Networks | Where-Object { $_.Status -in @('Disconnected', 'Disabled') }).Count -gt 0) {
        return 'Warning'
    }

    return 'Healthy'
}

function Get-FilteredNetworkInventory {
    param(
        [array]$Networks,

        [string]$Filter
    )

    if ([string]::IsNullOrWhiteSpace($Filter)) {
        return $Networks
    }

    return @($Networks | Where-Object {
            $_.AdapterName -like "*$Filter*" -or
            $_.InterfaceDescription -like "*$Filter*"
        })
}

function Get-NetworkSummary {
    param(
        [array]$Networks
    )

    $Connected = @($Networks | Where-Object { $_.Status -eq 'Up' }).Count
    $Disconnected = @($Networks | Where-Object { $_.Status -in @('Disconnected', 'Disabled') }).Count
    $DhcpEnabled = @($Networks | Where-Object { $_.DhcpEnabled -eq $true }).Count
    $StaticIp = @($Networks | Where-Object {
            $_.Status -eq 'Up' -and
            -not [string]::IsNullOrWhiteSpace($_.IPAddress) -and
            $_.DhcpEnabled -eq $false
        }).Count

    return [PSCustomObject]@{
        TotalAdapters        = $Networks.Count
        ConnectedAdapters    = $Connected
        DisconnectedAdapters = $Disconnected
        DhcpEnabledAdapters  = $DhcpEnabled
        StaticIpAdapters     = $StaticIp
    }
}

function Get-NetworkInventoryFromCmdlets {
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        $CimSession
    )

    $CmdletParams = @{}
    if ($CimSession) {
        $CmdletParams['CimSession'] = $CimSession
    }

    $Adapters = @(Get-NetAdapter @CmdletParams -ErrorAction Stop |
        Where-Object {
            $_.InterfaceDescription -notlike '*Loopback*' -and
            $_.InterfaceDescription -notlike '*Teredo*' -and
            $_.InterfaceDescription -notlike '*isatap*' -and
            $_.Name -notlike '*Bluetooth*'
        })

    $NetworkInventory = foreach ($Adapter in $Adapters) {
        $IpConfig = Get-NetIPConfiguration -InterfaceIndex $Adapter.InterfaceIndex @CmdletParams -ErrorAction SilentlyContinue
        $Ipv4     = $IpConfig.IPv4Address | Select-Object -First 1

        $IpAddress  = if ($Ipv4) { Get-FirstNetworkValue -Value $Ipv4.IPAddress } else { '' }
        $SubnetMask = if ($Ipv4 -and $Ipv4.PrefixLength -gt 0 -and $Ipv4.PrefixLength -le 32) {
            Convert-PrefixLengthToSubnetMask -PrefixLength $Ipv4.PrefixLength
        }
        else { '' }
        $Gateway = if ($IpConfig -and $IpConfig.IPv4DefaultGateway) {
            Get-FirstNetworkValue -Value $IpConfig.IPv4DefaultGateway.NextHop
        }
        else { '' }
        $DnsServers = if ($IpConfig -and $IpConfig.DNSServer) {
            @($IpConfig.DNSServer.ServerAddresses | Where-Object { $_ })
        }
        else { @() }
        $IpInterface = Get-NetIPInterface -InterfaceIndex $Adapter.InterfaceIndex -AddressFamily IPv4 @CmdletParams -ErrorAction SilentlyContinue
        $DhcpEnabled = if ($IpInterface) { $IpInterface.Dhcp -eq 'Enabled' } else { $false }

        $AdapterStatus = [string]$Adapter.Status

        [PSCustomObject]@{
            ComputerName         = $ComputerName
            AdapterName          = $Adapter.Name
            InterfaceDescription = $Adapter.InterfaceDescription
            Status               = $AdapterStatus
            MACAddress           = Format-NetworkMacAddress -MacAddress $Adapter.MacAddress
            IPAddress            = $IpAddress
            SubnetMask           = $SubnetMask
            DefaultGateway       = $Gateway
            DnsServers           = $DnsServers
            DnsServersDisplay    = ($DnsServers -join ', ')
            DhcpEnabled          = $DhcpEnabled
            LinkSpeedMbps        = Convert-LinkSpeedToMbps -LinkSpeed $Adapter.LinkSpeed
            HealthStatus         = Get-AdapterNetworkHealthStatus -Status $AdapterStatus
        }
    }

    return @($NetworkInventory)
}

function Get-NetworkInventoryFromCim {
    param(
        [Parameter(Mandatory)]
        [string]$ServerName,

        [Parameter(Mandatory)]
        [string]$ComputerName,

        [bool]$IsLocal
    )

    $CimParams = @{}
    if (-not $IsLocal) {
        $CimParams['ComputerName'] = $ServerName
    }

    $Adapters = @(Get-CimInstance -ClassName Win32_NetworkAdapter @CimParams -ErrorAction Stop |
        Where-Object {
            $_.PhysicalAdapter -or $_.AdapterType -eq 0
        } |
        Where-Object {
            $_.NetConnectionID -and
            $_.Name -notlike '*Bluetooth*'
        })

    $Configs = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration @CimParams -ErrorAction Stop)
    $NetworkInventory = @()

    foreach ($Adapter in $Adapters) {
        $Config = $Configs | Where-Object Index -eq $Adapter.Index | Select-Object -First 1

        $IpAddress  = ''
        $SubnetMask = ''
        $Gateway    = ''
        $DnsServers = @()
        $DhcpEnabled = $false

        if ($Config) {
            $IpAddress   = Get-FirstNetworkValue -Value @($Config.IPAddress | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
            $SubnetMask  = Get-FirstNetworkValue -Value @($Config.IPSubnet | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
            $Gateway     = Get-FirstNetworkValue -Value $Config.DefaultIPGateway
            $DnsServers  = @($Config.DNSServerSearchOrder | Where-Object { $_ })
            $DhcpEnabled = [bool]$Config.DHCPEnabled
        }

        $AdapterStatus = if ($Adapter.NetEnabled) { 'Up' } else { 'Disconnected' }

        $NetworkInventory += [PSCustomObject]@{
            ComputerName         = $ComputerName
            AdapterName          = $Adapter.NetConnectionID
            InterfaceDescription = $Adapter.Name
            Status               = $AdapterStatus
            MACAddress           = Format-NetworkMacAddress -MacAddress $Adapter.MACAddress
            IPAddress            = $IpAddress
            SubnetMask           = $SubnetMask
            DefaultGateway       = $Gateway
            DnsServers           = $DnsServers
            DnsServersDisplay    = ($DnsServers -join ', ')
            DhcpEnabled          = $DhcpEnabled
            LinkSpeedMbps        = if ($Adapter.Speed -and $Adapter.Speed -gt 0) { [math]::Round($Adapter.Speed / 1000000, 0) } else { 0 }
            HealthStatus         = Get-AdapterNetworkHealthStatus -Status $AdapterStatus
        }
    }

    return $NetworkInventory
}

function Get-NetworkInventory {
    <#
    .SYNOPSIS
        Collects network adapter configuration for a server.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ServerName,

        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [bool]$IsLocal
    )

    $CimSession = $null

    try {
        if (-not $IsLocal) {
            $CimSession = New-CimSession -ComputerName $ServerName -ErrorAction Stop
            return @(Get-NetworkInventoryFromCmdlets -ComputerName $ComputerName -CimSession $CimSession)
        }

        return @(Get-NetworkInventoryFromCmdlets -ComputerName $ComputerName)
    }
    catch {
        Write-Verbose "Network cmdlet collection failed for '$ServerName'. Falling back to CIM. $($_.Exception.Message)"

        try {
            return @(Get-NetworkInventoryFromCim -ServerName $ServerName -ComputerName $ComputerName -IsLocal $IsLocal)
        }
        catch {
            Write-Verbose "Unable to collect network inventory for '$ServerName': $($_.Exception.Message)"
            return @()
        }
    }
    finally {
        if ($CimSession) {
            Remove-CimSession -CimSession $CimSession -ErrorAction SilentlyContinue
        }
    }
}

function Write-NetworkConsoleTable {
    param(
        [array]$Networks
    )

    if (-not $Networks) {
        return
    }

    $Networks |
        Select-Object `
            @{Name = 'ComputerName'; Expression = { $_.ComputerName } }, `
            @{Name = 'AdapterName';  Expression = { $_.AdapterName } }, `
            @{Name = 'Status';       Expression = { $_.Status } }, `
            @{Name = 'IPAddress';    Expression = { $_.IPAddress } }, `
            @{Name = 'Gateway';      Expression = { $_.DefaultGateway } }, `
            @{Name = 'DHCP';         Expression = { $_.DhcpEnabled } } |
        Format-Table -Property ComputerName, AdapterName, Status, IPAddress, Gateway, DHCP -AutoSize |
        Out-String -Width 250 |
        ForEach-Object { Write-Host $_ }
}

function Get-ServiceInventory {
    <#
    .SYNOPSIS
        Collects monitored Windows service inventory for a server.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ServerName,

        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [bool]$IsLocal,

        [Parameter(Mandatory)]
        [string[]]$ServiceNames
    )

    $ServiceInventory = @()

    if ($IsLocal) {
        foreach ($Name in $ServiceNames) {
            $Service = Get-Service -Name $Name -ErrorAction SilentlyContinue

            if ($Service) {
                $ServiceStatus = $Service.Status.ToString()
                $StartType     = $Service.StartType.ToString()

                $ServiceInventory += [PSCustomObject]@{
                    ComputerName = $ComputerName
                    ServiceName  = $Service.Name
                    DisplayName  = $Service.DisplayName
                    Status       = $ServiceStatus
                    StartType    = $StartType
                    HealthStatus = Get-ServiceHealthStatus -Found $true -Status $ServiceStatus -StartType $StartType
                }
            }
            else {
                $ServiceInventory += [PSCustomObject]@{
                    ComputerName = $ComputerName
                    ServiceName  = $Name
                    DisplayName  = ''
                    Status       = 'Not Found'
                    StartType    = ''
                    HealthStatus = 'Unknown'
                }
            }
        }
    }
    else {
        $CimServices = @(Get-CimInstance -ClassName Win32_Service -ComputerName $ServerName -ErrorAction Stop |
            Where-Object { $_.Name -in $ServiceNames })

        foreach ($Name in $ServiceNames) {
            $Service = $CimServices | Where-Object Name -eq $Name | Select-Object -First 1

            if ($Service) {
                $ServiceStatus = $Service.State
                $StartType     = switch ($Service.StartMode) {
                    'Auto'   { 'Automatic' }
                    'Manual' { 'Manual' }
                    default  { $Service.StartMode }
                }

                $ServiceInventory += [PSCustomObject]@{
                    ComputerName = $ComputerName
                    ServiceName  = $Service.Name
                    DisplayName  = $Service.DisplayName
                    Status       = $ServiceStatus
                    StartType    = $StartType
                    HealthStatus = Get-ServiceHealthStatus -Found $true -Status $ServiceStatus -StartType $StartType
                }
            }
            else {
                $ServiceInventory += [PSCustomObject]@{
                    ComputerName = $ComputerName
                    ServiceName  = $Name
                    DisplayName  = ''
                    Status       = 'Not Found'
                    StartType    = ''
                    HealthStatus = 'Unknown'
                }
            }
        }
    }

    return $ServiceInventory
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

        $ServiceInventory = @(Get-ServiceInventory `
            -ServerName $ServerName `
            -ComputerName $SystemInventory.ComputerName `
            -IsLocal $IsLocal `
            -ServiceNames $MonitoredServices)

        $SoftwareInventory = @(Get-SoftwareInventory `
            -ServerName $ServerName `
            -ComputerName $SystemInventory.ComputerName `
            -IsLocal $IsLocal)

        try {
            $NetworkInventory = @(Get-NetworkInventory `
                -ServerName $ServerName `
                -ComputerName $SystemInventory.ComputerName `
                -IsLocal $IsLocal)
        }
        catch {
            Write-Verbose "Network inventory collection failed for '$ServerName': $($_.Exception.Message)"
            $NetworkInventory = @()
        }

        $NetworkHealthStatus = Get-ServerNetworkHealthStatus -Networks $NetworkInventory

        $SystemInventory.ServerStatus = Get-CombinedServerHealthStatus `
            -DiskStatuses @($DiskInventory.Status) `
            -ServiceHealthStatuses @($ServiceInventory.HealthStatus) `
            -NetworkHealthStatuses @($NetworkHealthStatus)

        return [PSCustomObject]@{
            System   = $SystemInventory
            Disks    = $DiskInventory
            Services = $ServiceInventory
            Software = $SoftwareInventory
            Networks = $NetworkInventory
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
            Disks    = @()
            Services = @()
            Software = @()
            Networks = @()
        }
    }
}

function Get-HtmlServerStatusTable {
    param(
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

function Get-HtmlServiceDetailsTable {
    param(
        [array]$Services
    )

    if (-not $Services) {
        return '<p class="no-data">No service information available.</p>'
    }

    $HtmlRows = foreach ($Service in $Services) {
        $StatusClass = Get-StatusCssClass -Status $Service.HealthStatus
        @"
        <tr>
            <td>$($Service.ComputerName)</td>
            <td>$($Service.ServiceName)</td>
            <td>$($Service.DisplayName)</td>
            <td>$($Service.Status)</td>
            <td>$($Service.StartType)</td>
            <td><span class="status-badge $StatusClass">$($Service.HealthStatus)</span></td>
        </tr>
"@
    }

    return @"
<table class="data-table">
    <thead>
        <tr>
            <th>Computer</th>
            <th>Service</th>
            <th>Display Name</th>
            <th>Status</th>
            <th>Start Type</th>
            <th>Health</th>
        </tr>
    </thead>
    <tbody>
        $($HtmlRows -join "`n")
    </tbody>
</table>
"@
}

function Get-HtmlSoftwareDetailsTable {
    param(
        [array]$Software
    )

    if (-not $Software) {
        return '<p class="no-data">No software information available.</p>'
    }

    $HtmlRows = foreach ($App in $Software) {
        @"
        <tr>
            <td>$($App.ComputerName)</td>
            <td>$($App.DisplayName)</td>
            <td>$($App.DisplayVersion)</td>
            <td>$($App.Publisher)</td>
            <td>$($App.InstallDate)</td>
        </tr>
"@
    }

    return @"
<div class="software-table-wrapper">
<table class="data-table software-table">
    <thead>
        <tr>
            <th>Computer</th>
            <th>Display Name</th>
            <th>Version</th>
            <th>Publisher</th>
            <th>Install Date</th>
        </tr>
    </thead>
    <tbody>
        $($HtmlRows -join "`n")
    </tbody>
</table>
</div>
"@
}

function Get-HtmlNetworkDetailsTable {
    param(
        [array]$Networks
    )

    if (-not $Networks) {
        return '<p class="no-data">No network information available.</p>'
    }

    $HtmlRows = foreach ($Network in $Networks) {
        $StatusClass = Get-StatusCssClass -Status $Network.HealthStatus
        $DhcpDisplay = if ($Network.DhcpEnabled) { 'Yes' } else { 'No' }
        @"
        <tr>
            <td>$($Network.ComputerName)</td>
            <td>$($Network.AdapterName)</td>
            <td><span class="status-badge $StatusClass">$($Network.Status)</span></td>
            <td>$($Network.IPAddress)</td>
            <td>$($Network.SubnetMask)</td>
            <td>$($Network.DefaultGateway)</td>
            <td>$($Network.DnsServersDisplay)</td>
            <td>$DhcpDisplay</td>
            <td>$($Network.LinkSpeedMbps) Mbps</td>
        </tr>
"@
    }

    return @"
<div class="software-table-wrapper">
<table class="data-table">
    <thead>
        <tr>
            <th>Computer</th>
            <th>Adapter</th>
            <th>Status</th>
            <th>IP Address</th>
            <th>Subnet Mask</th>
            <th>Gateway</th>
            <th>DNS Servers</th>
            <th>DHCP</th>
            <th>Link Speed</th>
        </tr>
    </thead>
    <tbody>
        $($HtmlRows -join "`n")
    </tbody>
</table>
</div>
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

        [AllowEmptyCollection()]
        $Servers,

        [AllowEmptyCollection()]
        $Disks,

        [AllowEmptyCollection()]
        $Services,

        [AllowEmptyCollection()]
        $Software,

        [AllowEmptyCollection()]
        $Networks,

        [Parameter(Mandatory)]
        [object]$NetworkSummary
    )

    $Servers  = @($Servers)
    $Disks    = @($Disks)
    $Services = @($Services)
    $Software = @($Software)
    $Networks = @($Networks)

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
            healthyDrives    = $Summary.HealthyDrives
            warningDrives    = $Summary.WarningDrives
            criticalDrives   = $Summary.CriticalDrives
            totalServices    = $Summary.TotalServices
            healthyServices  = $Summary.HealthyServices
            warningServices  = $Summary.WarningServices
            criticalServices      = $Summary.CriticalServices
            totalSoftwarePackages = $Summary.TotalSoftwarePackages
        }
        networkSummary = [ordered]@{
            totalAdapters        = $NetworkSummary.TotalAdapters
            connectedAdapters    = $NetworkSummary.ConnectedAdapters
            disconnectedAdapters = $NetworkSummary.DisconnectedAdapters
            dhcpEnabledAdapters  = $NetworkSummary.DhcpEnabledAdapters
            staticIpAdapters     = $NetworkSummary.StaticIpAdapters
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
        services = @(
            foreach ($Service in $Services) {
                [ordered]@{
                    computerName = $Service.ComputerName
                    serviceName  = $Service.ServiceName
                    displayName  = $Service.DisplayName
                    status       = $Service.Status
                    startType    = $Service.StartType
                    healthStatus = $Service.HealthStatus
                }
            }
        )
        software = @(
            foreach ($App in $Software) {
                [ordered]@{
                    computerName    = $App.ComputerName
                    displayName     = $App.DisplayName
                    displayVersion  = $App.DisplayVersion
                    publisher       = $App.Publisher
                    installDate     = $App.InstallDate
                    estimatedSizeMB = [double]$App.EstimatedSizeMB
                }
            }
        )
        networks = @(
            foreach ($Network in $Networks) {
                [ordered]@{
                    computerName         = $Network.ComputerName
                    adapterName          = $Network.AdapterName
                    interfaceDescription = $Network.InterfaceDescription
                    status               = $Network.Status
                    macAddress           = $Network.MACAddress
                    ipAddress            = $Network.IPAddress
                    subnetMask           = $Network.SubnetMask
                    defaultGateway       = $Network.DefaultGateway
                    dnsServers           = @($Network.DnsServers)
                    dhcpEnabled          = [bool]$Network.DhcpEnabled
                    linkSpeedMbps        = [double]$Network.LinkSpeedMbps
                    healthStatus         = $Network.HealthStatus
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

    $JsonReport | ConvertTo-Json -Depth 6 | Out-File -FilePath $Path -Encoding UTF8
}

function Write-ServiceConsoleTable {
    <#
    .SYNOPSIS
        Writes service inventory to the console in a readable table format.
    #>
    param(
        [array]$Services
    )

    if (-not $Services) {
        return
    }

    $Services |
        Select-Object `
            @{Name = 'ComputerName'; Expression = { $_.ComputerName } }, `
            @{Name = 'ServiceName';  Expression = { $_.ServiceName } }, `
            @{Name = 'Status';       Expression = { $_.Status } }, `
            @{Name = 'StartType';    Expression = { $_.StartType } }, `
            @{Name = 'HealthStatus'; Expression = { $_.HealthStatus } } |
        Format-Table -Property ComputerName, ServiceName, Status, StartType, HealthStatus -AutoSize |
        Out-String -Width 250 |
        ForEach-Object { Write-Host $_ }
}

function Write-DiskConsoleTable {
    <#
    .SYNOPSIS
        Writes disk inventory to the console in a readable table format.
    #>
    param(
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
        .status-unknown {
            background-color: #ede9fe;
            color: #5b21b6;
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
        .software-table-wrapper {
            max-height: 500px;
            overflow-y: auto;
            border: 1px solid #e5e7eb;
            border-radius: 8px;
        }
        .software-table thead th {
            position: sticky;
            top: 0;
            z-index: 1;
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

$AllServers  = @($InventoryResults | ForEach-Object { $_.System })
$AllDisks    = @(foreach ($Result in $InventoryResults) { foreach ($Disk in @($Result.Disks)) { $Disk } })
$AllServices = @(foreach ($Result in $InventoryResults) { foreach ($Service in @($Result.Services)) { $Service } })
$AllSoftware = @(foreach ($Result in $InventoryResults) { foreach ($App in @($Result.Software)) { $App } })
$AllNetworks = @(foreach ($Result in $InventoryResults) { foreach ($Network in @($Result.Networks)) { $Network } })

$ExportSoftware = @(Get-FilteredSoftwareInventory -Software $AllSoftware -Filter $SoftwareFilter)
$ExportNetworks = @(Get-FilteredNetworkInventory -Networks $AllNetworks -Filter $NetworkFilter)
$SoftwareSummary = Get-SoftwareSummary -Software $ExportSoftware
$NetworkSummary  = Get-NetworkSummary -Networks $ExportNetworks

# Dashboard Summary

$ServerSummary = [PSCustomObject]@{
    TotalServers     = $AllServers.Count
    HealthyServers   = @($AllServers | Where-Object ServerStatus -eq 'Healthy').Count
    WarningServers   = @($AllServers | Where-Object ServerStatus -eq 'Warning').Count
    CriticalServers  = @($AllServers | Where-Object ServerStatus -eq 'Critical').Count
    FailedServers    = @($AllServers | Where-Object ServerStatus -eq 'Unreachable').Count
    TotalDrives      = $AllDisks.Count
    HealthyDrives    = @($AllDisks | Where-Object Status -eq 'Healthy').Count
    WarningDrives    = @($AllDisks | Where-Object Status -eq 'Warning').Count
    CriticalDrives   = @($AllDisks | Where-Object Status -eq 'Critical').Count
    TotalServices    = $AllServices.Count
    HealthyServices  = @($AllServices | Where-Object HealthStatus -eq 'Healthy').Count
    WarningServices  = @($AllServices | Where-Object HealthStatus -eq 'Warning').Count
    CriticalServices      = @($AllServices | Where-Object HealthStatus -eq 'Critical').Count
    TotalSoftwarePackages = $SoftwareSummary.TotalSoftwarePackages
    TopSoftwarePublisher  = $SoftwareSummary.TopPublisher
    TotalAdapters         = $NetworkSummary.TotalAdapters
    ConnectedAdapters     = $NetworkSummary.ConnectedAdapters
    DisconnectedAdapters  = $NetworkSummary.DisconnectedAdapters
    DhcpEnabledAdapters   = $NetworkSummary.DhcpEnabledAdapters
    StaticIpAdapters      = $NetworkSummary.StaticIpAdapters
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
            ServiceName     = ''
            DisplayName     = ''
            DisplayVersion  = ''
            Publisher       = ''
            InstallDate     = ''
            EstimatedSizeMB = ''
            ServiceStatus   = ''
            StartType       = ''
            AdapterName          = ''
            InterfaceDescription = ''
            MacAddress           = ''
            IPAddress            = ''
            SubnetMask           = ''
            DefaultGateway       = ''
            DnsServers           = ''
            DhcpEnabled          = ''
            LinkSpeedMbps        = ''
            DriveLetter     = ''
            TotalSizeGB     = ''
            FreeSpaceGB     = ''
            FreePercent     = ''
            Status          = $Server.ServerStatus
            HealthStatus    = ''
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
            ServiceName     = ''
            DisplayName     = ''
            DisplayVersion  = ''
            Publisher       = ''
            InstallDate     = ''
            EstimatedSizeMB = ''
            ServiceStatus   = ''
            StartType       = ''
            AdapterName          = ''
            InterfaceDescription = ''
            MacAddress           = ''
            IPAddress            = ''
            SubnetMask           = ''
            DefaultGateway       = ''
            DnsServers           = ''
            DhcpEnabled          = ''
            LinkSpeedMbps        = ''
            DriveLetter     = $Disk.DriveLetter
            TotalSizeGB     = $Disk.TotalSizeGB
            FreeSpaceGB     = $Disk.FreeSpaceGB
            FreePercent     = $Disk.FreePercent
            Status          = $Disk.Status
            HealthStatus    = ''
        }
    }

    foreach ($Service in $AllServices) {
        $CsvExport += [PSCustomObject]@{
            RecordType      = 'Service'
            ServerName      = $Service.ComputerName
            ComputerName    = $Service.ComputerName
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
            ServiceName     = $Service.ServiceName
            DisplayName     = $Service.DisplayName
            DisplayVersion  = ''
            Publisher       = ''
            InstallDate     = ''
            EstimatedSizeMB = ''
            ServiceStatus   = $Service.Status
            StartType       = $Service.StartType
            AdapterName          = ''
            InterfaceDescription = ''
            MacAddress           = ''
            IPAddress            = ''
            SubnetMask           = ''
            DefaultGateway       = ''
            DnsServers           = ''
            DhcpEnabled          = ''
            LinkSpeedMbps        = ''
            DriveLetter     = ''
            TotalSizeGB     = ''
            FreeSpaceGB     = ''
            FreePercent     = ''
            Status          = $Service.Status
            HealthStatus    = $Service.HealthStatus
        }
    }

    foreach ($App in $ExportSoftware) {
        $CsvExport += [PSCustomObject]@{
            RecordType      = 'Software'
            ServerName      = $App.ComputerName
            ComputerName    = $App.ComputerName
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
            ServiceName     = ''
            DisplayName     = $App.DisplayName
            DisplayVersion  = $App.DisplayVersion
            Publisher       = $App.Publisher
            InstallDate     = $App.InstallDate
            EstimatedSizeMB = $App.EstimatedSizeMB
            ServiceStatus   = ''
            StartType       = ''
            AdapterName          = ''
            InterfaceDescription = ''
            MacAddress           = ''
            IPAddress            = ''
            SubnetMask           = ''
            DefaultGateway       = ''
            DnsServers           = ''
            DhcpEnabled          = ''
            LinkSpeedMbps        = ''
            DriveLetter     = ''
            TotalSizeGB     = ''
            FreeSpaceGB     = ''
            FreePercent     = ''
            Status          = ''
            HealthStatus    = ''
        }
    }

    foreach ($Network in $ExportNetworks) {
        $CsvExport += [PSCustomObject]@{
            RecordType           = 'Network'
            ServerName           = $Network.ComputerName
            ComputerName         = $Network.ComputerName
            OperatingSystem      = ''
            OSVersion            = ''
            Manufacturer         = ''
            Model                = ''
            TotalRAMGB           = ''
            FreeRAMGB            = ''
            BIOSVersion          = ''
            SerialNumber         = ''
            CPUName              = ''
            SystemUptime         = ''
            ServiceName          = ''
            DisplayName          = ''
            DisplayVersion       = ''
            Publisher            = ''
            InstallDate          = ''
            EstimatedSizeMB      = ''
            ServiceStatus        = ''
            StartType            = ''
            AdapterName          = $Network.AdapterName
            InterfaceDescription = $Network.InterfaceDescription
            MacAddress           = $Network.MACAddress
            IPAddress            = $Network.IPAddress
            SubnetMask           = $Network.SubnetMask
            DefaultGateway       = $Network.DefaultGateway
            DnsServers           = $Network.DnsServersDisplay
            DhcpEnabled          = $Network.DhcpEnabled
            LinkSpeedMbps        = $Network.LinkSpeedMbps
            DriveLetter          = ''
            TotalSizeGB          = ''
            FreeSpaceGB          = ''
            FreePercent          = ''
            Status               = $Network.Status
            HealthStatus         = $Network.HealthStatus
        }
    }

    $CsvExport | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8

    # HTML Report

    $ReportDate      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $ReportDateShort = Get-Date -Format 'yyyy-MM-dd'
    $CurrentUser     = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $ServerHtml   = Get-HtmlServerStatusTable -Servers $AllServers
    $DiskHtml     = Get-HtmlDiskDetailsTable -Disks $AllDisks
    $ServiceHtml  = Get-HtmlServiceDetailsTable -Services $AllServices
    $SoftwareHtml = Get-HtmlSoftwareDetailsTable -Software $ExportSoftware
    $NetworkHtml  = Get-HtmlNetworkDetailsTable -Networks $ExportNetworks
    $TopPublisherDisplay = if ($ServerSummary.TopSoftwarePublisher) { $ServerSummary.TopSoftwarePublisher } else { 'N/A' }

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

        <div class="summary-panel">
            <h2>Service Health Summary</h2>
            <div class="summary-grid">
                <div class="summary-card">
                    <div class="label">Total Services</div>
                    <div class="value">$($ServerSummary.TotalServices)</div>
                </div>
                <div class="summary-card healthy">
                    <div class="label">Healthy</div>
                    <div class="value">$($ServerSummary.HealthyServices)</div>
                </div>
                <div class="summary-card warning">
                    <div class="label">Warning</div>
                    <div class="value">$($ServerSummary.WarningServices)</div>
                </div>
                <div class="summary-card critical">
                    <div class="label">Critical</div>
                    <div class="value">$($ServerSummary.CriticalServices)</div>
                </div>
            </div>
        </div>

        <h2>Server Status</h2>
        $ServerHtml

        <h2>Disk Details</h2>
        $DiskHtml

        <h2>Service Inventory</h2>
        $ServiceHtml

        <div class="summary-panel">
            <h2>Software Inventory Summary</h2>
            <div class="summary-grid">
                <div class="summary-card">
                    <div class="label">Total Software Packages</div>
                    <div class="value">$($ServerSummary.TotalSoftwarePackages)</div>
                </div>
                <div class="summary-card">
                    <div class="label">Top Publisher</div>
                    <div class="value" style="font-size: 1rem;">$TopPublisherDisplay</div>
                </div>
            </div>
        </div>

        <h2>Software Inventory</h2>
        $SoftwareHtml

        <div class="summary-panel">
            <h2>Network Inventory Summary</h2>
            <div class="summary-grid">
                <div class="summary-card">
                    <div class="label">Total Adapters</div>
                    <div class="value">$($ServerSummary.TotalAdapters)</div>
                </div>
                <div class="summary-card healthy">
                    <div class="label">Connected</div>
                    <div class="value">$($ServerSummary.ConnectedAdapters)</div>
                </div>
                <div class="summary-card warning">
                    <div class="label">Disconnected</div>
                    <div class="value">$($ServerSummary.DisconnectedAdapters)</div>
                </div>
                <div class="summary-card">
                    <div class="label">DHCP Enabled</div>
                    <div class="value">$($ServerSummary.DhcpEnabledAdapters)</div>
                </div>
                <div class="summary-card">
                    <div class="label">Static IP</div>
                    <div class="value">$($ServerSummary.StaticIpAdapters)</div>
                </div>
            </div>
        </div>

        <h2>Network Inventory</h2>
        $NetworkHtml

        <div class="footer">
            <p>PowerShell Server Inventory Report $ScriptVersion</p>
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
        -Disks $AllDisks `
        -Services $AllServices `
        -Software $ExportSoftware `
        -Networks $ExportNetworks `
        -NetworkSummary $NetworkSummary
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
Write-Host 'Service Summary'
Write-Host '---------------'
Write-Host "Healthy Services  : $($ServerSummary.HealthyServices)"
Write-Host "Warning Services  : $($ServerSummary.WarningServices)"
Write-Host "Critical Services : $($ServerSummary.CriticalServices)"
Write-Host ''

$CriticalServices = @($AllServices | Where-Object HealthStatus -eq 'Critical')
if ($CriticalServices) {
    Write-Host 'Critical Services Detected'
    Write-Host '----------------------------'
    Write-ServiceConsoleTable -Services $CriticalServices
    Write-Host ''
}

Write-Host 'Software Summary'
Write-Host '----------------'
Write-Host "Total Software Packages : $($SoftwareSummary.TotalSoftwarePackages)"
Write-Host ''
Write-Host 'Top Publishers'
Write-Host ''
if ($SoftwareSummary.TopPublishers) {
    $SoftwareSummary.TopPublishers |
        Select-Object Publisher, Count |
        Format-Table -AutoSize |
        Out-String -Width 200 |
        ForEach-Object { Write-Host $_ }
}
else {
    Write-Host 'No publisher data available.'
    Write-Host ''
}

if ($SoftwareFilter) {
    Write-Host "Software Filter Applied : $SoftwareFilter"
    Write-Host ''
}

Write-Host 'Network Summary'
Write-Host '---------------'
Write-Host "Total Adapters        : $($NetworkSummary.TotalAdapters)"
Write-Host "Connected Adapters    : $($NetworkSummary.ConnectedAdapters)"
Write-Host "Disconnected Adapters : $($NetworkSummary.DisconnectedAdapters)"
Write-Host "DHCP Enabled          : $($NetworkSummary.DhcpEnabledAdapters)"
Write-Host "Static IP             : $($NetworkSummary.StaticIpAdapters)"
Write-Host ''

if ($NetworkFilter) {
    Write-Host "Network Filter Applied : $NetworkFilter"
    Write-Host ''
}

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

        if ($Result.Services) {
            Write-Host 'Service Information'
            Write-ServiceConsoleTable -Services $Result.Services
        }

        if ($Result.Networks) {
            Write-Host 'Network Information'
            $FilteredServerNetworks = @(Get-FilteredNetworkInventory -Networks $Result.Networks -Filter $NetworkFilter)
            Write-NetworkConsoleTable -Networks $FilteredServerNetworks
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
