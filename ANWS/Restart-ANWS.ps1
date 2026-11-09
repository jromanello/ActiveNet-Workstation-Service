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

        # If still not stopped, forcefully terminate service container process
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

    # Validate localhost port 4444 listener (ActiveNet Docs 000080830 & 000087155)
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
