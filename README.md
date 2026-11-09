# ActiveNet Workstation Service (ANWS) PowerShell Module

[![PowerShell Version](https://img.shields.io/badge/PowerShell-5.1%20%7C%207%2B-blue.svg)](https://github.com/PowerShell/PowerShell)
[![Module Version](https://img.shields.io/badge/Module-v2.0.0-green.svg)](https://github.com/jromanello/ActiveNet-Workstation-Service)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Enterprise-grade PowerShell module for deploying, hardening, recovering, and maintaining the **ActiveNet Workstation Service (ANWS)** across Windows endpoints.

---

## Overview

The ActiveNet Workstation Service connects browser-based ActiveNet recreation management sessions to local endpoint hardware (receipt printers, cash drawers, card readers, receipt scanners, and signature pads) via a localhost WebSocket listener on **port 4444**.

Version **2.0.0** modernizes the module to run natively across **Windows PowerShell 5.1** and **PowerShell 7+ (Core)**, embedding official ActiveNet technical knowledge base hardening, self-healing corrupted state recovery, non-admin operator workflows, and real-time WebSocket telemetry verification.

---

## What's New in v2.0.0

- **PowerShell 5.1 & 7+ Native Execution**: Eliminated external PowerShell 5 subprocess wrapping and legacy `PackageManagement` dependencies. All cmdlets execute natively across both Desktop and Core editions.
- **Corrupted State Self-Healing (MSI Error 1603 Remediation)**: Automatically detects when prior failed uninstallations or third-party cleaners removed the Windows service while retaining MSI registry metadata. Stages a transient service stub before uninstallation to guarantee clean MSI removal without Error 1603 aborts.
- **Official Automatic Service Recovery (Doc 000152060)**: Automates fail-safe service recovery configurations for both `activenetworkstationservice` and the dependent Windows `COMSysApp` (COM+ System Application).
- **Directory ACL Hardening (Doc 000157572)**: Grants `BUILTIN\Users` Full Control (`(OI)(CI)F`) over `%ProgramFiles(x86)%\ActiveNet Workstation Service` so standard user sessions, auto-updaters, and hardware drivers operate without file-access blocks.
- **Non-Admin Operator Restart Permissions**: Applies SDDL access control allowing standard Authenticated Users to stop and restart the service without requiring local administrative rights.
- **New `Restart-ANWS` Cmdlet**: Restarts the service and actively probes the localhost TCP port 4444 WebSocket listener to verify service health before returning.
- **Modernized Parameter Syntax & Resilient Downloads**: Enforces TLS 1.2, handles nested archive structures dynamically, and defaults working directories cleanly while respecting user overrides.

---

## Module Functions & Syntax

### 1. `Install-ANWS` (Alias: `Install-ActiveNet`)
Installs or upgrades ANWS from a remote ActiveNet download or a local/network archive.

#### Parameter Sets:
```powershell
# Parameter Set: Download (downloads latest package from ActiveNet)
Install-ANWS -Download [-Destination <string>] [-CreateShortcut] [-Verbose]

# Parameter Set: Source (uses existing .zip or .msi file)
Install-ANWS -Source <string> [-Destination <string>] [-CreateShortcut] [-Verbose]
```

- `-Download`: Downloads `activenetworkstationservice.zip` directly from `https://activenetmaint.active.com/upgrade/` over TLS 1.2 with exponential retry backoff.
- `-Source`: Path to a local or UNC network zip archive or MSI package.
- `-Destination`: Temporary staging directory. Defaults to `"$env:TEMP\ANWS_Install"` if omitted; custom paths (e.g. `'C:\Temp'`) are fully honored.
- `-CreateShortcut` (Alias: `-Shortcut`): Grants Authenticated Users SDDL restart permissions and creates a desktop restart shortcut with a hidden batch script.

#### Examples:
```powershell
# Download and install with full ActiveNet hardening
Install-ANWS -Download -CreateShortcut

# Install from a file share to a specific temporary folder
Install-ANWS -Source "\\FileServer\Deploy\activenetworkstationservice.zip" -Destination "C:\Temp\ANWS"
```

---

### 2. `Restart-ANWS` (Alias: `Restart-ActiveNet`)
Restarts the service and validates the port 4444 WebSocket listener.

```powershell
Restart-ANWS [-TimeoutSeconds <int>] [-Verbose]
```

- `-TimeoutSeconds`: Maximum time in seconds to wait for the service to start and the port 4444 WebSocket socket to accept connections. Defaults to `30`.
- Returns a rich `[PSCustomObject]` with `ServiceName`, `Status`, `Port4444Listening`, and `Success`.

#### Examples:
```powershell
# Restart service and verify port 4444
Restart-ANWS

# Restart with a 45-second timeout and verbose output
Restart-ActiveNet -TimeoutSeconds 45 -Verbose
```

---

### 3. `Set-ANWSRestart`
Grants Authenticated Users permissions to restart ANWS and generates a desktop shortcut.

```powershell
Set-ANWSRestart [-ShortcutLocation <string>] [-Verbose]
```

- `-ShortcutLocation`: Folder path for the desktop shortcut. Defaults to `"$env:PUBLIC\Desktop"`.
- Applies service SDDL:
  `D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;IU)(A;;CCLCSWLOCRRC;;;SU)(A;;RPWPCR;;;AU)S:(AU;FA;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;WD)`
- Creates a hidden `restartanws.bat` and a desktop shortcut `Restart ActiveNet.lnk`.

#### Examples:
```powershell
# Apply restart permissions and create public desktop shortcut
Set-ANWSRestart

# Create shortcut on a custom desktop path
Set-ANWSRestart -ShortcutLocation "C:\Users\Public\Desktop"
```

---

### 4. `Uninstall-ANWS` (Alias: `Uninstall-ActiveNet`)
Performs a hardened, clean uninstallation of ANWS with self-healing recovery.

```powershell
Uninstall-ANWS [-Verbose]
```

- Scans both 64-bit and WOW6432Node registry hives for ANWS ProductCode registrations.
- Recreates missing service stubs when encountering orphaned MSI registrations, preventing MSI Error 1603 aborts.
- Gracefully stops `activenetworkstationservice` and forcefully terminates locking processes (`ActiveNet.ServiceContainer.exe`, `ANWorkstationConfigurationUI.exe`, and embedded JRE `java.exe`/`javaw.exe`).
- Executes silent MSI removal via `msiexec.exe /x`.
- Double-checks and purges any orphaned services (`sc.exe delete`), residual service registry keys (`HKLM:\SYSTEM\CurrentControlSet\Services\activenetworkstationservice`), file system directories, and desktop shortcuts.

#### Examples:
```powershell
# Clean uninstallation
Uninstall-ANWS

# Verbose uninstallation
Uninstall-ActiveNet -Verbose
```

---

## ActiveNet Knowledge Base Alignment

This module strictly implements documented ActiveNet technical standards:

| Technical Requirement | ActiveNet Reference | Implementation Details |
|---|---|---|
| **Automatic Service Recovery** | Doc 000152060 | Configures first, second, and subsequent failures to restart service after 60,000 ms (1 min) with reset fail count after 0 days on both `activenetworkstationservice` and `COMSysApp`. |
| **Directory File Permissions** | Doc 000157572 | Grants `BUILTIN\Users` (`*S-1-5-32-545`) Full Control `(OI)(CI)F` on `%ProgramFiles(x86)%\ActiveNet Workstation Service`. |
| **Port & Process Architecture** | Docs 000080830 & 000087155 | WebSocket communication operates over `127.0.0.1:4444`. Monitored binaries include `ActiveNet.ServiceContainer.exe`, `ANWorkstationConfigurationUI.exe`, and embedded JRE processes. |
| **Standard User Elevation Bypass** | Doc 000157572 / Best Practice | Custom SDDL DACL grants `(A;;RPWPCR;;;AU)` (start/stop) to Authenticated Users, preventing elevation prompts for front-desk staff. |

---

## Installation & Import

Import the module directly in PowerShell:

```powershell
Import-Module "C:\Drive_D\Coding\Git\ActiveNet-Workstation-Service\ANWS\ANWS.psd1" -Force
```

To verify exported commands and aliases:

```powershell
Get-Command -Module ANWS
Get-Alias -Definition *-ANWS
```

---

## License

This project is licensed under the [MIT License](LICENSE).
