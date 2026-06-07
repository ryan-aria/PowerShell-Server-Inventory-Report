# PowerShell Server Inventory Report

A production-style PowerShell inventory reporting tool that collects system and disk information from a local Windows computer and exports results to CSV and HTML.

## Overview

**PowerShell Server Inventory Report** is designed for System Administrators who need a quick, repeatable way to document server hardware, operating system details, and disk usage. The script uses CIM/WMI and native PowerShell cmdlets, then exports professional reports suitable for audits, change records, and portfolio demonstrations.

## Features

- Collects computer name, OS, manufacturer, model, and serial number
- Reports total and free physical memory in GB
- Retrieves BIOS version, CPU name, and system uptime
- Gathers disk drive letter, total size, and free space per volume
- Exports combined inventory to `InventoryReport.csv`
- Generates a formatted `InventoryReport.html` report
- Includes comment-based help and `try/catch` error handling
- Displays results in the console and saves files to the `reports` folder

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

ComputerName DriveLetter TotalSizeGB FreeSpaceGB FreePercent
------------ ----------- ----------- ----------- -----------
DC01         C           127.5       84.2        66
DC01         D           500         312.8       62.6

CSV report saved to:  .\reports\InventoryReport.csv
HTML report saved to: .\reports\InventoryReport.html
```

### Exported Files

| File | Description |
|------|-------------|
| `InventoryReport.csv` | Combined system and disk inventory (RecordType: System / Disk) |
| `InventoryReport.html` | Formatted HTML report with system and disk tables |

## Technologies Used

- PowerShell
- WMI / CIM (`Get-CimInstance`)
- Storage cmdlets (`Get-Volume`)
- `Export-Csv` and `ConvertTo-Html`

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
