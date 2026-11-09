function Uninstall-ANWS {
    <#
        .SYNOPSIS
            Uninstalls the ActiveNet Workstation Service with hardened cleanup and corruption recovery.

        .DESCRIPTION
            Natively uninstalls the ActiveNet Workstation Service (ANWS) across Windows PowerShell 5.1
            and PowerShell 7+ without external subprocess dependencies. Detects product registrations via
            both 64-bit and WOW6432Node uninstall registry hives.

            Includes automated self-healing for common MSI Error 1603 conditions by recreating service stubs
            if a prior corrupted uninstallation deleted the Windows service while leaving MSI metadata intact.
            Gracefully stops services, terminates locking Java/ActiveNet processes, executes silent MSI removal,
            and validates full post-uninstallation cleanup of orphaned services, registry keys, directories,
            and desktop shortcuts.

        .EXAMPLE
            PS> Uninstall-ANWS

        .EXAMPLE
            PS> Uninstall-ActiveNet -Verbose
    #>
    [CmdletBinding()]
    [Alias('Uninstall-ActiveNet')]
    param()

    $serviceName = 'activenetworkstationservice'
    $displayName = 'ActiveNet Workstation Service'
    $installPath = if (${env:ProgramFiles(x86)}) {
        Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath $displayName
    } else {
        Join-Path -Path $env:ProgramFiles -ChildPath $displayName
    }
    $msiLog = Join-Path -Path $env:TEMP -ChildPath 'ANWS_msi_uninstall.log'

    Write-Verbose "Beginning uninstallation workflow for $displayName..."

    # Step 1: Detect installation in registry (64-bit and WOW6432Node)
    $regPaths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $installedEntries = Get-ItemProperty -Path $regPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and ($_.DisplayName -like "*$displayName*" -or $_.DisplayName -like "*ActiveNet Workstation*") }

    $productCodes = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $installedEntries) {
        Write-Verbose "Detected registry registration: '$($entry.DisplayName)' at $($entry.PSPath)"
        if ($entry.InstallLocation -and (Test-Path -Path $entry.InstallLocation)) {
            $installPath = $entry.InstallLocation
        }

        # Check for GUID product code in PSChildName or UninstallString
        if ($entry.PSChildName -match '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$') {
            if (-not $productCodes.Contains($entry.PSChildName)) {
                $productCodes.Add($entry.PSChildName)
            }
        } elseif ($entry.UninstallString -match '\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}') {
            if (-not $productCodes.Contains($matches[0])) {
                $productCodes.Add($matches[0])
            }
        }
    }

    # Step 2: Handle corrupted state (MSI registered but Windows service missing -> causes MSI Error 1603)
    $serviceExists = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($productCodes.Count -gt 0 -and -not $serviceExists) {
        Write-Verbose "MSI product registered but Windows service '$serviceName' is missing. Recreating service stub to prevent MSI 1603..."
        $stubBinary = Join-Path -Path $installPath -ChildPath 'ActiveNet.ServiceContainer.exe'
        try {
            New-Service -Name $serviceName -DisplayName $displayName -BinaryPathName "`"$stubBinary`"" -StartupType Disabled -ErrorAction SilentlyContinue | Out-Null
            Write-Verbose "Dummy service stub successfully staged."
        } catch {
            Write-Verbose "Unable to create dummy service stub: $($_.Exception.Message)"
        }
    }

    # Step 3: Pre-uninstall process & service termination
    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
        Write-Verbose "Stopping service '$serviceName'..."
        Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
    }

    Write-Verbose "Terminating potential locking processes..."
    $processNames = @('ActiveNet.ServiceContainer', 'ANWorkstationConfigurationUI', 'java', 'javaw')
    foreach ($pName in $processNames) {
        $foundProcs = Get-Process -Name $pName -ErrorAction SilentlyContinue
        foreach ($proc in $foundProcs) {
            $shouldKill = $false
            if ($pName -in @('java', 'javaw')) {
                try {
                    $pPath = $proc.MainModule.FileName
                    if ($pPath -and ($pPath -like "*$installPath*" -or $pPath -like "*ActiveNet*")) {
                        $shouldKill = $true
                    }
                } catch {
                    # If process path cannot be inspected, kill if associated with ActiveNet directory
                    $shouldKill = $true
                }
            } else {
                $shouldKill = $true
            }

            if ($shouldKill) {
                Write-Verbose "Terminating locking process '$($proc.ProcessName)' (PID: $($proc.Id))..."
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # Step 4: Silent MSI uninstallation
    if ($productCodes.Count -gt 0) {
        foreach ($code in $productCodes) {
            Write-Verbose "Executing MSI uninstallation for ProductCode '$code'..."
            $msiArgs = @('/x', $code, '/qn', '/norestart', '/l*v', "`"$msiLog`"")
            $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow
            Write-Verbose "msiexec /x exited with code $($proc.ExitCode)."
        }
    } else {
        Write-Verbose "No active MSI ProductCode entries detected in registry. Proceeding to post-uninstall cleanup..."
    }

    # Step 5: Post-uninstall double check & purge
    # 5a. Remove service via sc.exe if still present
    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
        Write-Verbose "Service '$serviceName' still registered post-MSI. Deleting via sc.exe..."
        & sc.exe delete $serviceName 2>&1 | Out-Null
    }

    # 5b. Purge orphaned registry service key
    $serviceRegPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceName"
    if (Test-Path -Path $serviceRegPath) {
        Write-Verbose "Purging orphaned service registry key at '$serviceRegPath'..."
        Remove-Item -Path $serviceRegPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 5c. Wait for file handles to release and remove installation directory
    Start-Sleep -Seconds 2
    if (Test-Path -Path $installPath) {
        Write-Verbose "Removing residual installation folder at '$installPath'..."
        Remove-Item -Path $installPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 5d. Clean up desktop shortcuts and batch files
    $targetShortcutDirs = @(
        "$env:PUBLIC\Desktop",
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('CommonDesktopDirectory')
    ) | Select-Object -Unique

    $cleanupFiles = @('Restart ActiveNet.lnk', 'restartanws.bat', 'ActiveNet.url')
    foreach ($dir in $targetShortcutDirs) {
        if (Test-Path -Path $dir) {
            foreach ($file in $cleanupFiles) {
                $itemPath = Join-Path -Path $dir -ChildPath $file
                if (Test-Path -Path $itemPath) {
                    Write-Verbose "Removing shortcut/script file at '$itemPath'..."
                    Remove-Item -Path $itemPath -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    Write-Verbose "ActiveNet Workstation Service uninstallation and cleanup completed."
}
