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

    # Start transcript for auditability
    try {
        Start-Transcript -Path $transcriptLog -Append -ErrorAction SilentlyContinue | Out-Null
    } catch {}

    Write-Verbose "=== ActiveNet Workstation Service Modernized Installation ==="
    Write-Verbose "Working Directory: $Destination"
    Write-Verbose "Target Install Path: $installPath"

    try {
        # Ensure working directory exists
        if (-not (Test-Path -Path $Destination)) {
            Write-Verbose "Creating directory '$Destination'..."
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        }

        # Step 1: Acquire installer package (Download or Copy)
        if ($Download) {
            # Enforce TLS 1.2 transport security
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
            # Validate Source path
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

        # Step 2: Extraction (if zip package)
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

            # Locate MSI dynamically across any nested folder structure
            $msiFile = Get-ChildItem -Path $extractPath -Filter '*.msi' -Recurse | Select-Object -First 1
            if (-not $msiFile) {
                throw "No MSI package (*.msi) found inside extracted archive at '$extractPath'."
            }
            $targetMsi = $msiFile.FullName
        } else {
            $targetMsi = $directMsiPath
        }

        Write-Verbose "Resolved MSI target: '$targetMsi'"

        # Step 3: Pre-install process & service cleanup to avoid file-in-use errors
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
