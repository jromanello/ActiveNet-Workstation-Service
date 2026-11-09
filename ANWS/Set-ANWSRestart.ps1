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
