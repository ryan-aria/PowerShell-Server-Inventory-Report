#Requires -Version 5.1

<#
.SYNOPSIS
    InfraOps Dashboard integration helpers for Windows inventory submission.

.DESCRIPTION
    Provides configuration loading, logging, payload validation, local archive,
    and API submission for POST /api/import/windows-inventory.
#>

$Script:InfraOpsScheduledTaskName = 'InfraOps Windows Collector'

function Get-CollectorConfig {
    <#
    .SYNOPSIS
        Loads collector configuration from config.json.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ConfigPath
    )

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path -Path $PSScriptRoot -ChildPath 'config.json'
    }

    if (-not (Test-Path -Path $ConfigPath)) {
        throw "Collector configuration file not found: $ConfigPath"
    }

    try {
        $RawConfig = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "Unable to read collector configuration '$ConfigPath'. $($_.Exception.Message)"
    }

    if ([string]::IsNullOrWhiteSpace($RawConfig.ApiUrl)) {
        throw 'Collector configuration is missing ApiUrl.'
    }

    $TimeoutSeconds = 30
    if ($null -ne $RawConfig.TimeoutSeconds) {
        $TimeoutSeconds = [int]$RawConfig.TimeoutSeconds
    }

    $SchedulingEnabled = $true
    $FrequencyHours    = 6

    if ($RawConfig.Scheduling) {
        if ($null -ne $RawConfig.Scheduling.Enabled) {
            $SchedulingEnabled = [bool]$RawConfig.Scheduling.Enabled
        }

        if ($null -ne $RawConfig.Scheduling.FrequencyHours) {
            $FrequencyHours = [int]$RawConfig.Scheduling.FrequencyHours
        }
    }

    if ($FrequencyHours -lt 1) {
        $FrequencyHours = 1
    }

    return [PSCustomObject]@{
        ApiUrl              = [string]$RawConfig.ApiUrl
        CollectorName       = [string]$RawConfig.CollectorName
        CollectorVersion    = [string]$RawConfig.CollectorVersion
        TimeoutSeconds      = $TimeoutSeconds
        ConfigPath          = $ConfigPath
        SchedulingEnabled   = $SchedulingEnabled
        SchedulingFrequencyHours = $FrequencyHours
    }
}

function Test-CollectorHealth {
    <#
    .SYNOPSIS
        Verifies collector operational prerequisites and logs warnings.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ConfigPath,

        [Parameter()]
        [string]$LogDirectory,

        [Parameter()]
        [string]$ExportsDirectory,

        [Parameter()]
        [string]$RuntimeDirectory
    )

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path -Path $PSScriptRoot -ChildPath 'config.json'
    }

    if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
        $LogDirectory = Join-Path -Path $PSScriptRoot -ChildPath 'logs'
    }

    if ([string]::IsNullOrWhiteSpace($ExportsDirectory)) {
        $ExportsDirectory = Join-Path -Path $PSScriptRoot -ChildPath 'exports'
    }

    if ([string]::IsNullOrWhiteSpace($RuntimeDirectory)) {
        $RuntimeDirectory = Join-Path -Path $PSScriptRoot -ChildPath 'runtime'
    }

    $Warnings = @()

    if (-not (Test-Path -Path $ConfigPath)) {
        $Warnings += "Configuration file not found: $ConfigPath"
    }
    else {
        try {
            $Config = Get-CollectorConfig -ConfigPath $ConfigPath
            if ([string]::IsNullOrWhiteSpace($Config.ApiUrl)) {
                $Warnings += 'API URL is not configured in config.json.'
            }
        }
        catch {
            $Warnings += $_.Exception.Message
        }
    }

    if (-not (Test-Path -Path $LogDirectory)) {
        $Warnings += "Logs folder not found: $LogDirectory"
    }

    if (-not (Test-Path -Path $ExportsDirectory)) {
        $Warnings += "Exports folder not found: $ExportsDirectory"
    }

    $HeartbeatPath = Join-Path -Path $RuntimeDirectory -ChildPath 'heartbeat.json'
    if (-not (Test-Path -Path $HeartbeatPath)) {
        $Warnings += "Heartbeat file not found: $HeartbeatPath"
    }

    foreach ($Warning in $Warnings) {
        if (Get-Command -Name Write-CollectorLog -ErrorAction SilentlyContinue) {
            Write-CollectorLog -Message "Health check warning: $Warning" -Level ERROR -LogDirectory $LogDirectory
        }
        else {
            Write-Warning $Warning
        }
    }

    return [PSCustomObject]@{
        Healthy  = ($Warnings.Count -eq 0)
        Warnings = $Warnings
    }
}

function Test-CollectorLock {
    <#
    .SYNOPSIS
        Returns true when a collector lock file is present.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$RuntimeDirectory
    )

    if ([string]::IsNullOrWhiteSpace($RuntimeDirectory)) {
        $RuntimeDirectory = Join-Path -Path $PSScriptRoot -ChildPath 'runtime'
    }

    $LockPath = Join-Path -Path $RuntimeDirectory -ChildPath 'collector.lock'
    return Test-Path -Path $LockPath
}

function Set-CollectorLock {
    <#
    .SYNOPSIS
        Creates a collector lock file for the current process.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$RuntimeDirectory
    )

    if ([string]::IsNullOrWhiteSpace($RuntimeDirectory)) {
        $RuntimeDirectory = Join-Path -Path $PSScriptRoot -ChildPath 'runtime'
    }

    if (-not (Test-Path -Path $RuntimeDirectory)) {
        New-Item -Path $RuntimeDirectory -ItemType Directory -Force | Out-Null
    }

    $LockPath = Join-Path -Path $RuntimeDirectory -ChildPath 'collector.lock'
    $LockContent = @{
        processId = $PID
        startedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        hostName  = $env:COMPUTERNAME
    }

    $LockContent | ConvertTo-Json | Out-File -FilePath $LockPath -Encoding UTF8 -Force
}

function Remove-CollectorLock {
    <#
    .SYNOPSIS
        Removes the collector lock file if present.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$RuntimeDirectory
    )

    if ([string]::IsNullOrWhiteSpace($RuntimeDirectory)) {
        $RuntimeDirectory = Join-Path -Path $PSScriptRoot -ChildPath 'runtime'
    }

    $LockPath = Join-Path -Path $RuntimeDirectory -ChildPath 'collector.lock'

    if (Test-Path -Path $LockPath) {
        Remove-Item -Path $LockPath -Force -ErrorAction SilentlyContinue
    }
}

function Update-CollectorHeartbeat {
    <#
    .SYNOPSIS
        Writes collector heartbeat status to runtime\heartbeat.json.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Success', 'Failed')]
        [string]$Status,

        [Parameter()]
        [string]$RunId,

        [Parameter()]
        [string]$RuntimeDirectory
    )

    if ([string]::IsNullOrWhiteSpace($RuntimeDirectory)) {
        $RuntimeDirectory = Join-Path -Path $PSScriptRoot -ChildPath 'runtime'
    }

    if (-not (Test-Path -Path $RuntimeDirectory)) {
        New-Item -Path $RuntimeDirectory -ItemType Directory -Force | Out-Null
    }

    $HeartbeatPath = Join-Path -Path $RuntimeDirectory -ChildPath 'heartbeat.json'
    $Heartbeat = [ordered]@{
        lastRun = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        status  = $Status
    }

    if (-not [string]::IsNullOrWhiteSpace($RunId)) {
        $Heartbeat.runId = $RunId
    }

    $Heartbeat | ConvertTo-Json | Out-File -FilePath $HeartbeatPath -Encoding UTF8 -Force
}

function Write-CollectorLog {
    <#
    .SYNOPSIS
        Writes a timestamped collector log entry to a daily log file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('INFO', 'ERROR')]
        [string]$Level = 'INFO',

        [Parameter()]
        [string]$LogDirectory
    )

    if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
        $LogDirectory = Join-Path -Path $PSScriptRoot -ChildPath 'logs'
    }

    if (-not (Test-Path -Path $LogDirectory)) {
        New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
    }

    $LogFileName = 'collector-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd')
    $LogPath     = Join-Path -Path $LogDirectory -ChildPath $LogFileName
    $Timestamp   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $Line        = '{0} {1} {2}' -f $Timestamp, $Level, $Message

    Add-Content -Path $LogPath -Value $Line -Encoding UTF8
}

function Export-InventoryJson {
    <#
    .SYNOPSIS
        Archives inventory JSON to the exports folder with retention cleanup.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $InventoryObject,

        [Parameter()]
        [string]$ExportsDirectory,

        [Parameter()]
        [int]$RetentionCount = 30
    )

    if ([string]::IsNullOrWhiteSpace($ExportsDirectory)) {
        $ExportsDirectory = Join-Path -Path $PSScriptRoot -ChildPath 'exports'
    }

    if (-not (Test-Path -Path $ExportsDirectory)) {
        New-Item -Path $ExportsDirectory -ItemType Directory -Force | Out-Null
    }

    $ArchiveFileName = 'windows-inventory-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
    $ArchivePath     = Join-Path -Path $ExportsDirectory -ChildPath $ArchiveFileName

    $InventoryObject | ConvertTo-Json -Depth 10 | Out-File -FilePath $ArchivePath -Encoding UTF8

    $ExistingExports = @(Get-ChildItem -Path $ExportsDirectory -Filter 'windows-inventory-*.json' |
        Sort-Object LastWriteTime -Descending)

    if ($ExistingExports.Count -gt $RetentionCount) {
        $ExportsToRemove = $ExistingExports | Select-Object -Skip $RetentionCount
        foreach ($ExportFile in $ExportsToRemove) {
            Remove-Item -Path $ExportFile.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    return $ArchivePath
}

function Test-InventoryPayload {
    <#
    .SYNOPSIS
        Validates required InfraOps Windows inventory payload fields.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $InventoryObject
    )

    $Errors = @()

    if ($null -eq $InventoryObject) {
        return [PSCustomObject]@{
            Valid  = $false
            Errors = @('inventory payload is required')
        }
    }

    $RequiredProperties = @(
        'reportVersion'
        'generatedAt'
        'sourceType'
        'serverSummary'
        'servers'
    )

    $IsDictionary = $InventoryObject -is [System.Collections.IDictionary]

    foreach ($PropertyName in $RequiredProperties) {
        $HasProperty = if ($IsDictionary) {
            $InventoryObject.Contains($PropertyName)
        }
        else {
            $null -ne $InventoryObject.PSObject.Properties[$PropertyName]
        }

        if (-not $HasProperty) {
            $Errors += "$PropertyName is missing"
        }
    }

    $ReportVersion = if ($IsDictionary) { $InventoryObject['reportVersion'] } else { $InventoryObject.reportVersion }
    $GeneratedAt   = if ($IsDictionary) { $InventoryObject['generatedAt'] } else { $InventoryObject.generatedAt }
    $SourceType    = if ($IsDictionary) { $InventoryObject['sourceType'] } else { $InventoryObject.sourceType }
    $ServerSummary = if ($IsDictionary) { $InventoryObject['serverSummary'] } else { $InventoryObject.serverSummary }
    $ServersValue  = if ($IsDictionary) { $InventoryObject['servers'] } else { $InventoryObject.servers }

    if ($IsDictionary) {
        $HasReportVersion = $InventoryObject.Contains('reportVersion')
        $HasGeneratedAt   = $InventoryObject.Contains('generatedAt')
        $HasSourceType    = $InventoryObject.Contains('sourceType')
        $HasServerSummary = $InventoryObject.Contains('serverSummary')
        $HasServers       = $InventoryObject.Contains('servers')
    }
    else {
        $HasReportVersion = $null -ne $InventoryObject.PSObject.Properties['reportVersion']
        $HasGeneratedAt   = $null -ne $InventoryObject.PSObject.Properties['generatedAt']
        $HasSourceType    = $null -ne $InventoryObject.PSObject.Properties['sourceType']
        $HasServerSummary = $null -ne $InventoryObject.PSObject.Properties['serverSummary']
        $HasServers       = $null -ne $InventoryObject.PSObject.Properties['servers']
    }

    if ($HasReportVersion -and [string]::IsNullOrWhiteSpace([string]$ReportVersion)) {
        $Errors += 'reportVersion is required'
    }

    if ($HasGeneratedAt -and [string]::IsNullOrWhiteSpace([string]$GeneratedAt)) {
        $Errors += 'generatedAt is required'
    }

    if ($HasSourceType) {
        if ([string]::IsNullOrWhiteSpace([string]$SourceType)) {
            $Errors += 'sourceType is required'
        }
        elseif ($SourceType -ne 'windows') {
            $Errors += 'sourceType must be windows'
        }
    }

    if ($HasServerSummary -and $null -eq $ServerSummary) {
        $Errors += 'serverSummary is required'
    }

    if ($HasServers) {
        $Servers = @($ServersValue)
        if ($Servers.Count -lt 1) {
            $Errors += 'servers must contain at least one server'
        }
    }

    return [PSCustomObject]@{
        Valid  = ($Errors.Count -eq 0)
        Errors = $Errors
    }
}

function Submit-Inventory {
    <#
    .SYNOPSIS
        Submits inventory JSON to the InfraOps Windows import API.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $InventoryObject,

        [Parameter(Mandatory)]
        $Config,

        [Parameter()]
        [string]$LogDirectory
    )

    $JsonBody = $InventoryObject | ConvertTo-Json -Depth 10

    try {
        $Response = Invoke-RestMethod `
            -Uri $Config.ApiUrl `
            -Method POST `
            -ContentType 'application/json' `
            -Body $JsonBody `
            -TimeoutSec $Config.TimeoutSeconds

        return [PSCustomObject]@{
            Success          = [bool]$Response.success
            RunId            = $Response.runId
            ServersImported  = $Response.serversImported
            Response         = $Response
            StatusCode       = 200
            ErrorMessage     = $null
        }
    }
    catch {
        $StatusCode   = $null
        $ErrorMessage = $_.Exception.Message
        $ResponseBody = $null

        if ($_.Exception.Response) {
            try {
                $StatusCode = [int]$_.Exception.Response.StatusCode
            }
            catch {
                $StatusCode = $null
            }

            try {
                $Reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $ResponseBody = $Reader.ReadToEnd()
                $Reader.Close()

                if (-not [string]::IsNullOrWhiteSpace($ResponseBody)) {
                    $ParsedBody = $ResponseBody | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if ($ParsedBody.message) {
                        $ErrorMessage = [string]$ParsedBody.message
                    }
                    elseif ($ParsedBody.errors) {
                        $ErrorMessage = (@($ParsedBody.errors) -join '; ')
                    }
                }
            }
            catch {
                # Keep the original exception message when response body parsing fails.
            }
        }

        Write-CollectorLog -Message 'ERROR Upload failed' -Level ERROR -LogDirectory $LogDirectory
        Write-CollectorLog -Message "API upload failure: $ErrorMessage" -Level ERROR -LogDirectory $LogDirectory

        return [PSCustomObject]@{
            Success         = $false
            RunId           = $null
            ServersImported = $null
            Response        = $null
            StatusCode      = $StatusCode
            ErrorMessage    = $ErrorMessage
        }
    }
}

function Submit-InfraOpsInventory {
    <#
    .SYNOPSIS
        Archives, validates, and uploads inventory to InfraOps Dashboard.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $InventoryObject,

        [Parameter()]
        [string]$ConfigPath,

        [Parameter()]
        [string]$ExportsDirectory,

        [Parameter()]
        [string]$LogDirectory
    )

    if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
        $LogDirectory = Join-Path -Path $PSScriptRoot -ChildPath 'logs'
    }

    if ([string]::IsNullOrWhiteSpace($ExportsDirectory)) {
        $ExportsDirectory = Join-Path -Path $PSScriptRoot -ChildPath 'exports'
    }

    $ArchivePath = Export-InventoryJson `
        -InventoryObject $InventoryObject `
        -ExportsDirectory $ExportsDirectory

    Write-CollectorLog -Message "Inventory archived to $ArchivePath" -LogDirectory $LogDirectory

    $Validation = Test-InventoryPayload -InventoryObject $InventoryObject
    if (-not $Validation.Valid) {
        $ValidationMessage = @($Validation.Errors) -join '; '
        Write-CollectorLog -Message "Payload validation failed: $ValidationMessage" -Level ERROR -LogDirectory $LogDirectory
        Write-Host 'Inventory upload failed.'
        Write-Host "Error: Payload validation failed. $ValidationMessage"
        return [PSCustomObject]@{
            Success         = $false
            RunId           = $null
            ServersImported = $null
            Archived        = $true
        }
    }

    try {
        $Config = Get-CollectorConfig -ConfigPath $ConfigPath
    }
    catch {
        Write-CollectorLog -Message $_.Exception.Message -Level ERROR -LogDirectory $LogDirectory
        Write-Host 'API unavailable.'
        Write-Host 'Inventory saved locally.'
        return [PSCustomObject]@{
            Success         = $false
            RunId           = $null
            ServersImported = $null
            Archived        = $true
        }
    }

    Write-CollectorLog -Message 'API upload start' -LogDirectory $LogDirectory

    $UploadResult = Submit-Inventory `
        -InventoryObject $InventoryObject `
        -Config $Config `
        -LogDirectory $LogDirectory

    if ($UploadResult.Success) {
        Write-CollectorLog -Message 'Upload successful' -LogDirectory $LogDirectory
        Write-Host 'Inventory upload successful.'
        Write-Host "Run ID: $($UploadResult.RunId)"
        Write-Host "Servers Imported: $($UploadResult.ServersImported)"
        return [PSCustomObject]@{
            Success         = $true
            RunId           = $UploadResult.RunId
            ServersImported = $UploadResult.ServersImported
            Archived        = $true
        }
    }

    Write-Host 'Inventory upload failed.'
    if ($UploadResult.StatusCode) {
        Write-Host "HTTP Status: $($UploadResult.StatusCode)"
    }
    if ($UploadResult.ErrorMessage) {
        Write-Host "Error: $($UploadResult.ErrorMessage)"
    }

    return [PSCustomObject]@{
        Success         = $false
        RunId           = $null
        ServersImported = $null
        Archived        = $true
    }
}
