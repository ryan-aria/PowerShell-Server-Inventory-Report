# PowerShell Server Inventory Report

A production-style PowerShell inventory reporting tool that collects system and disk information from a local Windows computer and exports results to CSV and HTML.

## Overview

**PowerShell Server Inventory Report** is designed for System Administrators who need a quick, repeatable way to document server hardware, operating system details, and disk usage. The script uses CIM/WMI and native PowerShell cmdlets, then exports professional reports suitable for audits, change records, and portfolio demonstrations.

**Current Version: v1.1**

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

### New in v1.1

- **Disk Health Status** — Automatic Healthy / Warning / Critical classification per drive
- **Color-Coded HTML Report** — Status badges with green, orange, and red styling
- **Summary Dashboard** — Drive health overview at the top of the HTML report
- **Improved System Layout** — Property | Value table format in HTML (cleaner and easier to read)
- **Report Generation Details** — Footer shows script name, current user, and report version

## Disk Health Status

Each disk is evaluated based on free space percentage (`FreePercent`):

| Free Space | Status | Meaning |
|------------|--------|---------|
| ≥ 20% | **Healthy** | Adequate free space |
| 10% – 19.9% | **Warning** | Low free space — plan cleanup or expansion |
| < 10% | **Critical** | Very low free space — immediate attention recommended |

Health status appears in:

- Console disk table (`Status` column)
- CSV export (`Status` column on disk rows)
- HTML report (color-coded status badges)

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- Windows Server or Windows client with CIM/WMI access
- Write permissions to the output directory (default: `.\reports`)

## Usage

1. Clone or download this repository.
2. Open PowerShell and navigate to the project folder:

   ```powershell
   cd PowerShell-Server-Inventory-Report
   ```

3. Run the script:

   ```powershell
   .\ServerInventoryReport.ps1
   ```

4. Optional — specify a custom output path:

   ```powershell
   .\ServerInventoryReport.ps1 -OutputPath 'C:\Reports'
   ```

5. Open the generated files:

   - `reports\InventoryReport.csv`
   - `reports\InventoryReport.html`

## Example Output

### Console

```
===============================
 Server Inventory Report
===============================

System Information
------------------

ComputerName    : DC01
OperatingSystem : Microsoft Windows Server 2022 Standard
OSVersion       : 10.0.20348
Manufacturer    : Dell Inc.
Model           : PowerEdge R740
TotalRAMGB      : 32
FreeRAMGB       : 18.45
BIOSVersion     : 2.15.0
SerialNumber    : ABCD1234
CPUName         : Intel(R) Xeon(R) Gold 6230 CPU @ 2.10GHz
SystemUptime    : 14 days, 6 hours, 22 minutes

Disk Information
----------------

ComputerName DriveLetter TotalSizeGB FreeSpaceGB FreePercent Status
------------ ----------- ----------- ----------- ----------- ------
DC01         C           127.5       84.2        66          Healthy
DC01         D           500         8.5         1.7         Critical

CSV report saved to:  .\reports\InventoryReport.csv
HTML report saved to: .\reports\InventoryReport.html
```

### Exported Files

| File | Description |
|------|-------------|
| `InventoryReport.csv` | Combined system and disk inventory (RecordType: System / Disk) |
| `InventoryReport.html` | Dashboard-style HTML report with summary, system info, and disk health |

## Screenshots

Add screenshots of the HTML report to the `screenshots` folder for documentation and portfolio use.

![Server Inventory Report](screenshots/server-inventory-report.png)

## Technologies Used

- PowerShell
- WMI / CIM (`Get-CimInstance`)
- Storage cmdlets (`Get-Volume`)
- `Export-Csv` and custom HTML generation

## Version History

| Version | Description |
|---------|-------------|
| **v1.0** | Basic inventory collection — system info, disk details, CSV and HTML export |
| **v1.1** | Disk health monitoring, color-coded dashboard, summary section, improved HTML layout |

## Future Enhancements

- Multi-server inventory from a server list file
- Scheduled task deployment guide
- Network adapter and IP address reporting
- Installed software and Windows Update status
- Export to JSON for automation pipelines
- Email report delivery option
- Azure VM inventory integration

## License

Provided for learning and portfolio use. Fork, extend, and adapt for your environment.
