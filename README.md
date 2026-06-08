# PowerShell Server Inventory Report

A production-style PowerShell inventory reporting tool that collects system and disk information from multiple Windows servers and exports results to CSV, HTML, and JSON.

## Overview

**PowerShell Server Inventory Report** is designed for System Administrators who need a quick, repeatable way to document server hardware, operating system details, and disk usage across one or many systems. The script uses CIM/WMI for remote collection, evaluates server and disk health, and exports professional reports suitable for audits, change records, and portfolio demonstrations.

**Current Version: v1.3**

## Features

### Core Inventory (v1.0)

- Collects computer name, OS, manufacturer, model, and serial number
- Reports total and free physical memory in GB
- Retrieves BIOS version, CPU name, and system uptime
- Gathers disk drive letter, total size, and free space per volume
- Exports combined inventory to `InventoryReport.csv`
- Generates a formatted `InventoryReport.html` report
- Includes comment-based help and `try/catch` error handling
- Displays results in the console and saves files to the `reports` folder

### Disk Health Dashboard (v1.1)

- **Disk Health Status** — Automatic Healthy / Warning / Critical classification per drive
- **Color-Coded HTML Report** — Status badges with green, orange, and red styling
- **Summary Dashboard** — Drive health overview in the HTML report
- **Improved System Layout** — Property | Value table format (single-server HTML, superseded by v1.2 dashboard for multi-server)
- **Report Generation Details** — Footer shows script name, current user, and report version

### Multi-Server Inventory (v1.2)

- **Multi-Server Support** — Reads server names from `servers.txt`
- **Remote Collection** — Gathers inventory from remote servers via CIM
- **Server Health Evaluation** — Healthy / Warning / Critical based on worst disk status
- **Unreachable Server Handling** — Failed servers recorded as `Unreachable` without stopping execution
- **Dashboard Summary** — Total, Healthy, Warning, Critical, and Failed server counts
- **Server Status Table** — All servers with inventory and health status in HTML
- **Disk Details Table** — Combined disk inventory across all servers

### JSON Export (v1.3)

- **JSON Report** — Exports `InventoryReport.json` alongside CSV and HTML
- **InfraOps Dashboard Ready** — Structured camelCase JSON designed as a collector engine for the future InfraOps Dashboard web application
- **Machine-Readable Output** — Includes server summary, server inventory, disk details, and failed server records
- **API-Friendly Schema** — Consistent property names suitable for ingestion by web dashboards and automation pipelines

## Server List Configuration

Create or edit `servers.txt` in the project root:

```text
# Production servers
localhost
SRV01
SRV02

# Add one server name per line
# Lines starting with # are ignored
# Blank lines are skipped
```

## Disk Health Status

Each disk is evaluated based on free space percentage (`FreePercent`):

| Free Space | Status | Meaning |
|------------|--------|---------|
| ≥ 20% | **Healthy** | Adequate free space |
| 10% – 19.9% | **Warning** | Low free space — plan cleanup or expansion |
| < 10% | **Critical** | Very low free space — immediate attention recommended |

### Server Health Rules

| Condition | Server Status |
|-----------|---------------|
| Any disk is Critical | **Critical** |
| Any disk is Warning (no Critical) | **Warning** |
| All disks Healthy | **Healthy** |
| Server cannot be reached | **Unreachable** |

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- Windows Server or Windows client with CIM/WMI access
- Network connectivity and permissions for remote WMI/CIM (remote servers)
- Write permissions to the output directory (default: `.\reports`)

## Usage

1. Clone or download this repository.
2. Edit `servers.txt` with your target server names.
3. Open PowerShell and navigate to the project folder:

   ```powershell
   cd PowerShell-Server-Inventory-Report
   ```

4. Run the script:

   ```powershell
   .\ServerInventoryReport.ps1
   ```

5. Optional parameters:

   ```powershell
   .\ServerInventoryReport.ps1 -OutputPath 'C:\Reports'
   .\ServerInventoryReport.ps1 -ServerListFile '.\my-servers.txt'
   ```

6. Open the generated files:

   - `reports\InventoryReport.csv`
   - `reports\InventoryReport.html`
   - `reports\InventoryReport.json`

## Example Output

### Console

```
===============================
 Server Inventory Report
===============================

Server Summary
--------------

TotalServers    : 3
HealthyServers  : 1
WarningServers  : 1
CriticalServers : 1
FailedServers   : 0
TotalDrives     : 4
HealthyDrives   : 2
WarningDrives   : 1
CriticalDrives  : 1

Server: DRAGON [Critical]
----------------------------------------
...

CSV report saved to:  .\reports\InventoryReport.csv
HTML report saved to: .\reports\InventoryReport.html
JSON report saved to: .\reports\InventoryReport.json
```

### Exported Files

| File | Description |
|------|-------------|
| `InventoryReport.csv` | All server and disk records (RecordType: Server / Disk) |
| `InventoryReport.html` | Multi-server dashboard with summary, server status, and disk details |
| `InventoryReport.json` | Structured JSON for InfraOps Dashboard and automation integration |

### JSON Structure

```json
{
  "reportVersion": "v1.3",
  "generatedAt": "2026-06-07T19:30:00",
  "generatedBy": "ServerInventoryReport.ps1",
  "serverSummary": {
    "totalServers": 1,
    "healthyServers": 0,
    "warningServers": 0,
    "criticalServers": 1,
    "failedServers": 0,
    "totalDrives": 2,
    "healthyDrives": 0,
    "warningDrives": 1,
    "criticalDrives": 1
  },
  "servers": [
    {
      "computerName": "DRAGON",
      "operatingSystem": "Microsoft Windows 11 Pro",
      "osVersion": "10.0.26200",
      "serverStatus": "Critical"
    }
  ],
  "disks": [
    {
      "computerName": "DRAGON",
      "driveLetter": "C",
      "totalSizeGB": 117.91,
      "freeSpaceGB": 9.47,
      "freePercent": 8,
      "status": "Critical"
    }
  ],
  "failedServers": []
}
```

## Screenshots

Add screenshots of the HTML report to the `screenshots` folder for documentation and portfolio use.

![Server Inventory Report](screenshots/server-inventory-report.png)

## Technologies Used

- PowerShell
- WMI / CIM (`Get-CimInstance`)
- Storage cmdlets (`Get-Volume` for local disks)
- `Export-Csv`, `ConvertTo-Json`, and custom HTML generation

## Version History

| Version | Description |
|---------|-------------|
| **v1.0** | Initial release — basic inventory collection, CSV and HTML export |
| **v1.1** | Disk health dashboard — health status, color-coded HTML, summary section |
| **v1.2** | Multi-server inventory — remote collection, server health evaluation, unreachable handling |
| **v1.3** | JSON export — InfraOps Dashboard integration, machine-readable collector output |

## Future Enhancements

- InfraOps Dashboard web application integration
- Credential parameter for remote authentication
- Scheduled task deployment guide
- Network adapter and IP address reporting
- Installed software and Windows Update status
- Email report delivery option
- Azure VM inventory integration

## License

Provided for learning and portfolio use. Fork, extend, and adapt for your environment.
