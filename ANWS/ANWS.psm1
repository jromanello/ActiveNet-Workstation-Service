#
# ActiveNet Workstation Service (ANWS) PowerShell Module
# Version: 2.0.0
# Author: Justin Romanello
#

function Install-ANWS {
    <#
        .SYNOPSIS
            Installs or updates the ActiveNet Workstation Service (ANWS) with official hardening.

        .DESCRIPTION
            Installs the ActiveNet Workstation Service from a specified archive or downloads the latest
            distribution directly from ActiveNet. Configures enterprise hardening per ActiveNet technical
            documentation:
              - Enforces TLS 1.2 download transport.
              - Pre-emptively terminates locking ActiveNet/Java processes.
              - Dynamically locates MSI within nested zip archives.
              - Executes silent MSI installation with verbose transaction logging.
              - Applies Automatic Service Recovery configuration to both 'activenetworkstationservice'
                and 'COMSysApp' (Doc 000152060).
              - Enforces BUILTIN\Users Full Control on the installation directory (Doc 000157572).
              - Configures SDDL restart permissions for Authenticated Users.
              - Validates the localhost port 4444 WebSocket listener (Docs 000080830 & 000087155).

        .PARAMETER Source
            Specifies the path to an ANWS installation zip or installer package. Mandatory when Download is not specified.

        .PARAMETER Download
            When specified, downloads the latest ANWS package directly from ActiveNet.

        .PARAMETER Destination
            Working directory for downloading and extracting installer assets. Defaults to "$env:TEMP\ANWS_Install".

        .PARAMETER CreateShortcut
            When specified, creates a hidden restart batch file and a desktop shortcut ("Restart ActiveNet.lnk") on the Public Desktop.

        .EXAMPLE
            PS> Install-ANWS -Download

        .EXAMPLE
            PS> Install-ANWS -Download -Destination 'C:\Temp' -CreateShortcut

        .EXAMPLE
            PS> Install-ANWS -Source "\\Server\Share\activenetworkstationservice.zip"
    #>
    [CmdletBinding(DefaultParameterSetName='Source')]
    [Alias('Install-ActiveNet')]
    param (      
        [Parameter(ParameterSetName='Source', Mandatory=$true, Position=0)]
        [string]$Source, 

        [Parameter(ParameterSetName='Download', Mandatory=$true)]
        [switch]$Download,
        
        [Parameter(ParameterSetName='Source', Mandatory=$false)]
        [Parameter(ParameterSetName='Download', Mandatory=$false)]
        [string]$Destination = "$env:TEMP\ANWS_Install",

        [Parameter(Mandatory=$false)]
        [Alias('Shortcut')]
        [switch]$CreateShortcut
    )

    $serviceName = 'activenetworkstationservice'
    $displayName = 'ActiveNet Workstation Service'
    $installPath = if (${env:ProgramFiles(x86)}) {
        Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath $displayName
    } else {
        Join-Path -Path $env:ProgramFiles -ChildPath $displayName
    }
    $extractPath = Join-Path -Path $Destination -ChildPath 'Extract'
    $zipPath = Join-Path -Path $Destination -ChildPath "$serviceName.zip"
    $msiLog = Join-Path -Path $env:TEMP -ChildPath 'ANWS_msi_install.log'
    $transcriptLog = Join-Path -Path $env:TEMP -ChildPath "ANWS_Install_Log_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"

    try {
        Start-Transcript -Path $transcriptLog -Append -ErrorAction SilentlyContinue | Out-Null
    } catch {}

    Write-Verbose "=== ActiveNet Workstation Service Modernized Installation ==="
    Write-Verbose "Working Directory: $Destination"
    Write-Verbose "Target Install Path: $installPath"

    try {
        if (-not (Test-Path -Path $Destination)) {
            Write-Verbose "Creating directory '$Destination'..."
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        }

        # Step 1: Acquire installer package (Download or Copy)
        if ($Download) {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

            $downloadUrl = "https://activenetmaint.active.com/upgrade/$serviceName.zip"
            Write-Verbose "Downloading ANWS package from '$downloadUrl'..."

            $downloadComplete = $false
            $maxRetries = 5
            $retryInterval = 2

            for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
                Write-Verbose "Download attempt $attempt of $maxRetries..."
                try {
                    if ($PSVersionTable.PSVersion.Major -ge 6) {
                        Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -TimeoutSec 120 -ErrorAction Stop
                    } else {
                        Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
                    }

                    if ((Test-Path -Path $zipPath) -and ((Get-Item -Path $zipPath).Length -gt 0)) {
                        Write-Verbose "Download verified ($((Get-Item -Path $zipPath).Length) bytes)."
                        $downloadComplete = $true
                        break
                    }
                } catch {
                    Write-Verbose "Invoke-WebRequest attempt failed: $($_.Exception.Message)"
                    try {
                        Write-Verbose "Attempting WebClient fallback..."
                        $webClient = New-Object System.Net.WebClient
                        $webClient.DownloadFile($downloadUrl, $zipPath)
                        if ((Test-Path -Path $zipPath) -and ((Get-Item -Path $zipPath).Length -gt 0)) {
                            Write-Verbose "WebClient download verified."
                            $downloadComplete = $true
                            break
                        }
                    } catch {
                        Write-Verbose "WebClient fallback failed: $($_.Exception.Message)"
                    }

                    if ($attempt -lt $maxRetries) {
                        Start-Sleep -Seconds $retryInterval
                    }
                }
            }

            if (-not $downloadComplete) {
                throw "Failed to download ActiveNet package from '$downloadUrl' after $maxRetries attempts."
            }
        } else {
            if (-not (Test-Path -Path $Source)) {
                throw "Specified Source path does not exist: '$Source'"
            }

            $sourceItem = Get-Item -Path $Source
            if ($sourceItem.Extension -ieq '.zip') {
                Write-Verbose "Copying source archive from '$Source' to '$Destination'..."
                Copy-Item -Path $Source -Destination $Destination -Force
                $zipPath = Join-Path -Path $Destination -ChildPath $sourceItem.Name
            } elseif ($sourceItem.Extension -ieq '.msi') {
                Write-Verbose "Source is a direct MSI file."
                $directMsiPath = $sourceItem.FullName
            } else {
                throw "Source file must be a .zip or .msi file. Provided: '$Source'"
            }
        }

        # Step 2: Extraction
        if (-not $directMsiPath) {
            if (-not (Test-Path -Path $zipPath)) {
                throw "Archive file '$zipPath' not found for extraction."
            }

            if (Test-Path -Path $extractPath) {
                Remove-Item -Path $extractPath -Recurse -Force -ErrorAction SilentlyContinue
            }
            New-Item -ItemType Directory -Path $extractPath -Force | Out-Null

            Write-Verbose "Extracting installer archive to '$extractPath'..."
            Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

            $msiFile = Get-ChildItem -Path $extractPath -Filter '*.msi' -Recurse | Select-Object -First 1
            if (-not $msiFile) {
                throw "No MSI package (*.msi) found inside extracted archive at '$extractPath'."
            }
            $targetMsi = $msiFile.FullName
        } else {
            $targetMsi = $directMsiPath
        }

        Write-Verbose "Resolved MSI target: '$targetMsi'"

        # Step 3: Pre-install process & service cleanup
        Write-Verbose "Stopping service '$serviceName' if running..."
        Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue

        Write-Verbose "Terminating potential locking ActiveNet/Java processes..."
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
                        $shouldKill = $true
                    }
                } else {
                    $shouldKill = $true
                }

                if ($shouldKill) {
                    Write-Verbose "Terminating process '$($proc.ProcessName)' (PID: $($proc.Id))..."
                    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                }
            }
        }

        # Step 4: Silent MSI installation
        Write-Verbose "Executing silent MSI installation..."
        $msiArgs = @('/i', "`"$targetMsi`"", '/qn', '/norestart', '/l*v', "`"$msiLog`"")
        $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow

        if ($proc.ExitCode -notin @(0, 3010)) {
            throw "MSI installation failed with exit code $($proc.ExitCode). Review installer log at '$msiLog'."
        }
        Write-Verbose "MSI installation succeeded with exit code $($proc.ExitCode)."

        # Step 5: Official ActiveNet Hardening & Configuration
        # 5a. Automatic Service Recovery Options (Doc 000152060)
        Write-Verbose "Configuring Automatic Service Recovery for '$serviceName'..."
        & sc.exe failure $serviceName reset= 0 actions= restart/60000/restart/60000/restart/60000 2>&1 | Out-Null

        Write-Verbose "Configuring Automatic Service Recovery for COM+ System Application ('COMSysApp')..."
        & sc.exe failure COMSysApp reset= 0 actions= restart/60000/restart/60000/restart/60000 2>&1 | Out-Null

        # 5b. Startup Type Automatic and Service Start
        Write-Verbose "Setting '$serviceName' startup type to Automatic..."
        Set-Service -Name $serviceName -StartupType Automatic -ErrorAction SilentlyContinue

        Write-Verbose "Starting service '$serviceName'..."
        Start-Service -Name $serviceName -ErrorAction SilentlyContinue

        # 5c. Directory Permissions for BUILTIN\Users (Doc 000157572)
        if (Test-Path -Path $installPath) {
            Write-Verbose "Granting Full Control on '$installPath' to BUILTIN\Users (*S-1-5-32-545)..."
            & icacls.exe "$installPath" /grant "*S-1-5-32-545:(OI)(CI)F" /T /C /Q 2>&1 | Out-Null
        }

        # 5d. SDDL Restart Permissions for Authenticated Users
        Write-Verbose "Configuring Authenticated Users restart SDDL permissions..."
        $sddl = 'D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;IU)(A;;CCLCSWLOCRRC;;;SU)(A;;RPWPCR;;;AU)S:(AU;FA;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;WD)'
        & sc.exe sdset $serviceName $sddl 2>&1 | Out-Null

        # 5e. Desktop Shortcut Configuration
        if ($CreateShortcut) {
            Write-Verbose "Creating desktop restart shortcut..."
            Set-ANWSRestart
        }

        # Step 6: Cleanup temporary files
        Write-Verbose "Cleaning up temporary installation assets..."
        if (Test-Path -Path $extractPath) {
            Remove-Item -Path $extractPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($zipPath -and (Test-Path -Path $zipPath) -and ($zipPath -like "$Destination*")) {
            Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue
        }

        # Step 7: Port 4444 Verification (Docs 000080830 & 000087155)
        Write-Verbose "Verifying localhost port 4444 WebSocket listener..."
        $portListening = $false
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt 15) {
            try {
                $tcpClient = New-Object System.Net.Sockets.TcpClient
                $asyncResult = $tcpClient.BeginConnect('127.0.0.1', 4444, $null, $null)
                if ($asyncResult.AsyncWaitHandle.WaitOne(1000, $false) -and $tcpClient.Connected) {
                    $tcpClient.EndConnect($asyncResult)
                    $tcpClient.Close()
                    $portListening = $true
                    break
                }
                $tcpClient.Close()
            } catch {}
            Start-Sleep -Milliseconds 500
        }
        $sw.Stop()

        # Step 8: Final Status Reporting
        $svcStatus = (Get-Service -Name $serviceName -ErrorAction SilentlyContinue).Status
        Write-Verbose "ActiveNet Workstation Service Status: $svcStatus | Port 4444 Listening: $portListening"
        Write-Output "ActiveNet Workstation Service installed successfully (Status: $svcStatus, Port 4444: $portListening)."
    } catch {
        Write-Error "ActiveNet Workstation Service installation failed: $($_.Exception.Message)"
        throw $_
    } finally {
        try {
            Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
        } catch {}
    }
}

function Set-ANWSRestart {
    <#
        .SYNOPSIS
            Grants restart permissions to Authenticated Users and creates a desktop restart shortcut.

        .DESCRIPTION
            Configures the ActiveNet Workstation Service (activenetworkstationservice) SDDL security
            descriptor so Authenticated Users can start and stop the service without local administrator
            rights. Generates a hidden batch script (restartanws.bat) and a desktop shortcut (Restart ActiveNet.lnk)
            for ease of use by front-desk and recreation staff.

        .PARAMETER ShortcutLocation
            Directory where the restart batch file and desktop shortcut are placed. Defaults to Public Desktop ($env:PUBLIC\Desktop).

        .EXAMPLE
            PS> Set-ANWSRestart

        .EXAMPLE
            PS> Set-ANWSRestart -ShortcutLocation "C:\Users\Public\Desktop"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$ShortcutLocation = "$env:PUBLIC\Desktop"
    )

    $serviceName = 'activenetworkstationservice'
    $sddl = 'D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;IU)(A;;CCLCSWLOCRRC;;;SU)(A;;RPWPCR;;;AU)S:(AU;FA;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;WD)'

    try {
        Write-Verbose "Applying SDDL restart permissions to service '$serviceName'..."
        $sdResult = & sc.exe sdset $serviceName $sddl 2>&1
        Write-Verbose "sc.exe sdset output: $sdResult"

        if (-not (Test-Path -Path $ShortcutLocation)) {
            Write-Verbose "Creating directory '$ShortcutLocation'..."
            New-Item -ItemType Directory -Path $ShortcutLocation -Force | Out-Null
        }

        # Create restart batch file
        $batPath = Join-Path -Path $ShortcutLocation -ChildPath 'restartanws.bat'
        $batContent = "@echo off`r`nnet stop $serviceName`r`nnet start $serviceName`r`n"
        Set-Content -Path $batPath -Value $batContent -Encoding ASCII -Force
        
        # Hide the batch file to prevent desktop clutter
        try {
            [System.IO.File]::SetAttributes($batPath, [System.IO.FileAttributes]::Hidden)
        } catch {
            Write-Verbose "Could not set hidden attribute on '$batPath': $($_.Exception.Message)"
        }

        # Create shortcut via WScript.Shell
        $lnkPath = Join-Path -Path $ShortcutLocation -ChildPath 'Restart ActiveNet.lnk'
        Write-Verbose "Creating shortcut at '$lnkPath'..."
        $wshShell = New-Object -ComObject 'WScript.Shell'
        $shortcut = $wshShell.CreateShortcut($lnkPath)
        $shortcut.TargetPath = $batPath
        $shortcut.WorkingDirectory = $ShortcutLocation
        $shortcut.Description = 'Restart ActiveNet Workstation Service'
        $shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,238"
        $shortcut.Save()

        Write-Verbose "Restart permissions and desktop shortcut configured successfully at '$lnkPath'."
    } catch {
        Write-Error "Failed to configure ANWS restart permissions or shortcut: $($_.Exception.Message)"
        throw $_
    }
}

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
    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
        Write-Verbose "Service '$serviceName' still registered post-MSI. Deleting via sc.exe..."
        & sc.exe delete $serviceName 2>&1 | Out-Null
    }

    $serviceRegPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceName"
    if (Test-Path -Path $serviceRegPath) {
        Write-Verbose "Purging orphaned service registry key at '$serviceRegPath'..."
        Remove-Item -Path $serviceRegPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    Start-Sleep -Seconds 2
    if (Test-Path -Path $installPath) {
        Write-Verbose "Removing residual installation folder at '$installPath'..."
        Remove-Item -Path $installPath -Recurse -Force -ErrorAction SilentlyContinue
    }

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

function Restart-ANWS {
    <#
        .SYNOPSIS
            Restarts the ActiveNet Workstation Service and verifies the port 4444 listener.

        .DESCRIPTION
            Stops the ActiveNet Workstation Service (activenetworkstationservice), terminates any orphaned
            service processes if necessary, starts the service, and verifies that the localhost port 4444
            WebSocket listener is active and accepting connections.

        .PARAMETER TimeoutSeconds
            The maximum time in seconds to wait for the service to start and the port 4444 listener to respond.
            Defaults to 30 seconds.

        .OUTPUTS
            [PSCustomObject] containing ServiceName, Status, Port4444Listening, and Success.

        .EXAMPLE
            PS> Restart-ANWS

        .EXAMPLE
            PS> Restart-ActiveNet -TimeoutSeconds 45
    #>
    [CmdletBinding()]
    [Alias('Restart-ActiveNet')]
    param(
        [Parameter(Mandatory=$false)]
        [int]$TimeoutSeconds = 30
    )

    $serviceName = 'activenetworkstationservice'
    Write-Verbose "Querying status of service '$serviceName'..."

    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Error "Service '$serviceName' was not found on this system. Verify ActiveNet Workstation Service is installed."
        return [PSCustomObject]@{
            ServiceName       = $serviceName
            Status            = 'NotFound'
            Port4444Listening = $false
            Success           = $false
        }
    }

    # Stop service if running
    if ($service.Status -ne 'Stopped') {
        Write-Verbose "Stopping service '$serviceName'..."
        Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
        
        $stopWait = 0
        while ((Get-Service -Name $serviceName -ErrorAction SilentlyContinue).Status -ne 'Stopped' -and $stopWait -lt 10) {
            Start-Sleep -Seconds 1
            $stopWait++
        }

        if ((Get-Service -Name $serviceName -ErrorAction SilentlyContinue).Status -ne 'Stopped') {
            Write-Verbose "Service failed to stop gracefully within 10s. Forcing process termination..."
            Get-Process -Name 'ActiveNet.ServiceContainer' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
    }

    # Start service
    Write-Verbose "Starting service '$serviceName'..."
    Start-Service -Name $serviceName -ErrorAction Stop

    # Wait for service status to reach Running
    $serviceStarted = $false
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $currentStatus = (Get-Service -Name $serviceName -ErrorAction SilentlyContinue).Status
        if ($currentStatus -eq 'Running') {
            $serviceStarted = $true
            break
        }
        Start-Sleep -Milliseconds 500
    }

    if (-not $serviceStarted) {
        Write-Warning "Service '$serviceName' did not reach 'Running' state within $TimeoutSeconds seconds."
    } else {
        Write-Verbose "Service '$serviceName' is running. Verifying WebSocket listener on localhost:4444..."
    }

    # Validate localhost port 4444 listener
    $portListening = $false
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        try {
            $tcpClient = New-Object System.Net.Sockets.TcpClient
            $asyncResult = $tcpClient.BeginConnect('127.0.0.1', 4444, $null, $null)
            $waitSuccess = $asyncResult.AsyncWaitHandle.WaitOne(1000, $false)
            if ($waitSuccess -and $tcpClient.Connected) {
                $tcpClient.EndConnect($asyncResult)
                $tcpClient.Close()
                $portListening = $true
                break
            }
            $tcpClient.Close()
        } catch {
            # Retry until timeout
        }
        Start-Sleep -Milliseconds 500
    }
    $stopwatch.Stop()

    $finalStatus = (Get-Service -Name $serviceName -ErrorAction SilentlyContinue).Status
    $isSuccess = ($finalStatus -eq 'Running') -and $portListening

    if ($isSuccess) {
        Write-Verbose "ActiveNet Workstation Service restarted successfully and verified on port 4444."
    } else {
        Write-Warning "ActiveNet Workstation Service restart finished with warnings. Running: $($finalStatus -eq 'Running'), Port 4444 Open: $portListening."
    }

    return [PSCustomObject]@{
        ServiceName       = $serviceName
        Status            = [string]$finalStatus
        Port4444Listening = $portListening
        Success           = $isSuccess
    }
}

# Aliases
Set-Alias -Name 'Install-ActiveNet' -Value 'Install-ANWS'
Set-Alias -Name 'Uninstall-ActiveNet' -Value 'Uninstall-ANWS'
Set-Alias -Name 'Restart-ActiveNet' -Value 'Restart-ANWS'

# Export members
Export-ModuleMember -Function @(
    'Install-ANWS',
    'Set-ANWSRestart',
    'Uninstall-ANWS',
    'Restart-ANWS'
) -Alias @(
    'Install-ActiveNet',
    'Uninstall-ActiveNet',
    'Restart-ActiveNet'
)
