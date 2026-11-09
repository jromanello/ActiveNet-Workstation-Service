@{
    # Script module or binary module file associated with this manifest.
    RootModule = 'ANWS.psm1'

    # Version number of this module.
    ModuleVersion = '2.0.0'

    # Supported PSEditions
    CompatiblePSEditions = @('Desktop', 'Core')

    # ID used to uniquely identify this module
    GUID = '2e352d18-c34f-4e5b-8e2b-f246b4da5785'

    # Author of this module
    Author = 'Justin Romanello'

    # Company or vendor of this module
    CompanyName = 'No Company'

    # Copyright statement for this module
    Copyright = '(c) Justin Romanello. All rights reserved.'

    # Description of the functionality provided by this module
    Description = 'Enterprise management, hardening, and recovery module for the ActiveNet Workstation Service (ANWS).'

    # Minimum version of the PowerShell engine required by this module. Compatible with PowerShell 5.1 and PowerShell 7+.
    PowerShellVersion = '5.1'

    # Functions to export from this module
    FunctionsToExport = @('Install-ANWS', 'Set-ANWSRestart', 'Uninstall-ANWS', 'Restart-ANWS')

    # Cmdlets to export from this module
    CmdletsToExport = @()

    # Variables to export from this module
    VariablesToExport = @()

    # Aliases to export from this module
    AliasesToExport = @('Install-ActiveNet', 'Uninstall-ActiveNet', 'Restart-ActiveNet')

    # Private data to pass to the module specified in RootModule/ModuleToProcess.
    PrivateData = @{
        PSData = @{
            # Tags applied to this module.
            Tags = @('ActiveNet', 'ActiveNetWorkstation', 'ActiveNetWorkstationService', 'ANWS', 'EndpointManagement')

            # A URL to the license for this module.
            LicenseUri = 'https://opensource.org/licenses/MIT'

            # A URL to the main website for this project.
            ProjectUri = 'https://github.com/jromanello/ActiveNet-Workstation-Service'

            # Release notes for this version
            ReleaseNotes = @'
v2.0.0 Modernized Enterprise Release:
- Support across Windows PowerShell 5.1 and PowerShell 7+ Core.
- Native uninstallation without external PowerShell 5 process wrapping.
- Automated self-healing for MSI Error 1603.
- Enforced TLS 1.2 download transport with improved retry logic.
- Improved MSI locator.
- Automatic Service Recovery configuration for both activenetworkstationservice and COMSysApp.
- BUILTIN\Users Full Control directory ACL enforcement.
- Authenticated Users SDDL service restart permissions with desktop shortcut and hidden batch script.
- Added Restart-ANWS cmdlet with localhost:4444 WebSocket port listener verification.
- Exported aliases: Install-ActiveNet, Uninstall-ActiveNet, Restart-ActiveNet.
'@
        } # End of PSData hashtable
    } # End of PrivateData hashtable
} # End of manifest hashtable
