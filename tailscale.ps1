[CmdletBinding()]
param (
    [Parameter(Position = 0)]
    [ValidateSet('connect', 'disconnect', 'help')]
    [string]$Command,

    [Parameter()]
    [Alias('auth-key')]
    [string]$AuthKey,

    [Parameter()]
    [Alias('advertise-tags')]
    [string[]]$AdvertiseTags,
    
    [Parameter()]
    [Alias('h')]
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

# Configuration
$script:Config = @{
    AuthKey         = ''  # Optionally set a default auth key
    DefaultTags     = @('')  # Optionally set default tags
    TempDir        = $env:TEMP
    InstallDir     = Join-Path $env:ProgramFiles 'Tailscale'
    BaseUrl        = 'https://pkgs.tailscale.com'
    MsiArgs        = @(
        'TS_ADMINCONSOLE=hide'
        'TS_ADVERTISEEXITNODE=never'
        'TS_ALLOWINCOMINGCONNECTIONS=never'
        'TS_CHECKUPDATES=always'
        'TS_ENABLEDNS=always'
        'TS_ENABLESUBNETS=always'
        'TS_EXITNODEMENU=hide'
        'TS_INSTALLUPDATES=always'
        'TS_NETWORKDEVICES=hide'
        'TS_NOLAUNCH=true'
        'TS_PREFERENCESMENU=hide'
        'TS_TESTMENU=hide'
        'TS_UNATTENDEDMODE=always'
        'TS_UPDATEMENU=hide'
    )
}

function Assert-AdminPrivileges {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        throw "This script requires administrator privileges. Please run from an elevated terminal."
    }
}

function Format-Tags {
    param (
        [string[]]$Tags
    )
    
    if (-not $Tags) { return $null }
    
    $formattedTags = $Tags | Where-Object { $_ } | ForEach-Object {
        if ($_ -notlike "tag:*") {
            "tag:$_"
        } else {
            $_
        }
    }
    
    return $formattedTags -join ','
}

function Get-TailscaleInstaller {
    [CmdletBinding()]
    param()
    
    # Check for an existing installer in the installation directory
    $existingInstaller = Get-ChildItem -Path $script:Config.InstallDir -Filter "tailscale-setup-*.msi" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($existingInstaller) {
        Write-Verbose "Found existing installer: $($existingInstaller.FullName)"
        return $existingInstaller.FullName
    }

    Write-Host "Downloading latest Tailscale installer..."
    $latestUrl = "$($script:Config.BaseUrl)/stable/tailscale-setup-latest-amd64.msi"
    
    try {
        $ProgressPreference = 'SilentlyContinue'

        # Create web request to get the redirect location
        $request = [System.Net.WebRequest]::Create($latestUrl)
        $request.AllowAutoRedirect = $false
        $request.Method = "HEAD"
        
        $response = $request.GetResponse()
        Write-Verbose "Response status: $($response.StatusCode)"
        
        # Get redirect location and build the actual URL
        $location = $response.Headers["Location"]
        $actualUrl = "$($script:Config.BaseUrl)$location"
        Write-Verbose "Redirect URL: $actualUrl"
        
        # Download the MSI installer
        $fileName = Split-Path $actualUrl -Leaf
        $installerPath = Join-Path $script:Config.TempDir $fileName
        
        Write-Verbose "Downloading to: $installerPath"
        Invoke-WebRequest -Uri $actualUrl -OutFile $installerPath
        
        return $installerPath
    }
    catch {
        throw "Failed to download Tailscale installer: $_"
    }
    finally {
        if ($response) { $response.Dispose() }
    }
}

function Install-Tailscale {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallerPath,
        [Parameter(Mandatory = $true)]
        [string]$AuthKey,
        [string[]]$Tags
    )

    # Build installation arguments
    $msiArgs = @("/i", "`"$InstallerPath`"", "/quiet") + $script:Config.MsiArgs

    # Build Tailscale CLI arguments
    $cliArgs = @('up', '--unattended')
    $cliArgs += "--auth-key=$AuthKey"
    
    if ($Tags) {
        $formattedTags = Format-Tags -Tags $Tags
        if ($formattedTags) {
            $cliArgs += "--advertise-tags=$formattedTags"
        }
    }

    Write-Host "Installing Tailscale..."
    $result = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow
    
    if ($result.ExitCode -ne 0) {
        throw "Installation failed with exit code: $($result.ExitCode)"
    }

    $null = New-Item -ItemType Directory -Path $script:Config.InstallDir -Force -ErrorAction SilentlyContinue
    Move-Item -Path $InstallerPath -Destination $script:Config.InstallDir -Force

    # Move the MSI into the installation directory for future reference
    Write-Host "Authenticating with Tailscale..."
    $tailscaleExe = Join-Path $script:Config.InstallDir 'tailscale.exe'
    Write-Verbose "Running Tailscale with arguments: $($cliArgs -join ' ')"
    $result = Start-Process $tailscaleExe -ArgumentList $cliArgs -Wait -PassThru -NoNewWindow
    
    if ($result.ExitCode -ne 0) {
        throw "Authentication failed with exit code: $($result.ExitCode)"
    }

    Write-Host "Successfully installed and authenticated"
}

function Uninstall-Tailscale {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallerPath
    )

    Write-Host "Stopping Tailscale processes..."
    
    Get-Process -Name "tailscale-ipn" -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Verbose "Stopping tailscale-ipn process (PID: $($_.Id))"
        $_ | Stop-Process -Force
    }

    Get-Process -Name "tailscaled" -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Verbose "Stopping tailscaled process (PID: $($_.Id))"
        $_ | Stop-Process -Force
    }

    if (Get-Service -Name "Tailscale" -ErrorAction SilentlyContinue) {
        Write-Verbose "Stopping Tailscale service"
        Stop-Service -Name "Tailscale" -Force -ErrorAction SilentlyContinue
    }

    Start-Sleep -Seconds 2

    Write-Host "Uninstalling Tailscale..."
    $result = Start-Process msiexec.exe -ArgumentList "/x", "`"$InstallerPath`"", "/quiet" -Wait -PassThru -NoNewWindow
    
    if ($result.ExitCode -ne 0) {
        throw "Uninstallation failed with exit code: $($result.ExitCode)"
    }

    $cleanupPaths = @(
        $script:Config.InstallDir
        (Join-Path $env:ProgramData 'Tailscale')
        (Join-Path $env:LOCALAPPDATA 'Tailscale')
    )

    foreach ($path in $cleanupPaths) {
        if (Test-Path $path) {
            Remove-Item $path -Recurse -Force
            Write-Host "Cleaned up $path"
        }
    }

    Write-Host "Successfully uninstalled"
}

function Show-Help {
    Write-Host @"
THIS SCRIPT MUST BE RUN AS ADMINISTRATOR

Usage:
    .\tailscale.ps1 <command> [options]

Commands:
    connect     Install Tailscale and connect to your Tailnet
    disconnect  Remove Tailscale and disconnect from your Tailnet
    help        Show this help message

Options:
    -AuthKey         Specify auth key for the 'connect' command
    -AdvertiseTags   Specify list of tags (e.g., "dev", "prod"), 'tag:' prefix optional

Examples:
    .\tailscale.ps1 connect -AuthKey "tskey-abcdef12345" -AdvertiseTags "eng","prod"
    .\tailscale.ps1 disconnect
"@
}

try {
    if ($Help -or $Command -eq 'help') {
        Show-Help
        exit 0
    }

    Assert-AdminPrivileges
    
    switch ($Command.ToLower()) {
        'connect' {
            $installerPath = Get-TailscaleInstaller
            
            # Handle auth key (prompt if not supplied or configured by default)
            $useAuthKey = $AuthKey
            if (-not $useAuthKey) { $useAuthKey = $script:Config.AuthKey }
            while (-not $useAuthKey) {
                $useAuthKey = Read-Host "Please enter your Tailscale Auth key"
            }
            
            # Handle tags (prompt if not supplied or configured by default)
            $useTags = @()
            if ($AdvertiseTags) {
                $useTags = $AdvertiseTags
            }
            elseif ($script:Config.DefaultTags) {
                $useTags = $script:Config.DefaultTags
            }
            else {
                $tagInput = Read-Host "Enter tags (optional, comma-separated)"
                if ($tagInput) {
                    $useTags = $tagInput -split '[,\s]+'
                }
            }
            
            Install-Tailscale -InstallerPath $installerPath -AuthKey $useAuthKey -Tags $useTags
        }
        'disconnect' {
            $installerPath = Get-TailscaleInstaller
            Uninstall-Tailscale -InstallerPath $installerPath
        }
        default {
            if ($Command) {
                Write-Error "Invalid command: $Command"
                Show-Help
                exit 1
            }
            else {
                Show-Help
                exit 0
            }
        }
    }
}
catch {
    Write-Error -ErrorRecord $_
    exit 1
}