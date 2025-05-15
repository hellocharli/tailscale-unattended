[CmdletBinding()]
param (
    [Parameter(Position = 0)]
    [ValidateSet('connect', 'disconnect', 'help')]
    [string]$Command,
    [Alias('auth-key')][string]$AuthKey,
    [Alias('advertise-tags')][string[]]$AdvertiseTags,
    [Alias('h')][switch]$Help
)

$ErrorActionPreference = 'Stop'

# Configuration
$script:Config = @{
    AuthKey     = ''  # Optionally set a default auth key
    DefaultTags = @('')  # Optionally set default tags
    TempDir     = $env:TEMP
    InstallDir  = Join-Path $env:ProgramFiles 'Tailscale'
    BaseUrl     = 'https://pkgs.tailscale.com'
    MsiArgs     = @(
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
    param([string[]]$Tags)
    ($Tags | Where-Object { $_ } | ForEach-Object {
        if ($_ -notlike 'tag:*') { "tag:$_" } else { $_ }
    }) -join ','
}

function Get-TailscaleInstaller {
    [CmdletBinding()]
    param()

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
    catch { throw "Failed to download Tailscale installer: $_" }
    finally {
        if ($response) { $response.Dispose() }
    }
}

function Install-Tailscale {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallerPath,
        [Parameter(Mandatory = $true)][string]$AuthKey,
        [string[]]$Tags
    )

    Write-Host "Installing Tailscale..."
    $msiArgs = @("/i", "`"$InstallerPath`"", "/quiet") + $script:Config.MsiArgs
    $result = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
    if ($result.ExitCode -ne 0) { throw "MSI install failed: $($result.ExitCode)" }

    Write-Host "Waiting for Tailscale service to start..."
    $serviceName = "Tailscale"
    Start-Service -Name $serviceName -ErrorAction SilentlyContinue

    $maxWait = 15
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (
        ((Get-Service -Name $serviceName).Status -ne 'Running') -and
        ($sw.Elapsed.TotalSeconds -lt $maxWait)
    ) {
        Start-Sleep -Seconds 1
    }
    if ((Get-Service -Name $serviceName).Status -ne 'Running') {
        throw "Tailscale service failed to start!" 
    }
    Write-Host "Tailscale service running."

    Write-Host "Bringing Tailscale up..."
    $tailscaleExe = Join-Path $script:Config.InstallDir 'tailscale.exe'
    $upArgs = @('up', '--unattended', "--auth-key=$AuthKey", "--reset")
    if ($Tags) {
        $formattedTags = Format-Tags -Tags $Tags
        if ($formattedTags) {
            $upArgs += "--advertise-tags=$formattedTags"
        }
    }
    $result = Start-Process $tailscaleExe -ArgumentList $upArgs -Wait -NoNewWindow -PassThru
    if ($result.ExitCode -ne 0) { throw "tailscale up failed: $($result.ExitCode)" }

    Write-Verbose "Cleaning up MSI installer"
    Remove-Item $InstallerPath -Force -ErrorAction SilentlyContinue
    Write-Host "Successfully installed and authenticated"
}

function Uninstall-Tailscale {
    $tailscaleExe = Join-Path $script:Config.InstallDir 'tailscale.exe'

    if (Test-Path $tailscaleExe) {
        Write-Host "Bringing Tailscale down'..."
        try { & $tailscaleExe down | Out-Null }
        catch { Write-Warning "Failed to run 'tailscale down': $_" }
    }
    else {
        Write-Warning "tailscale.exe not found, skipping 'down' step."
    }

    Write-Host "Uninstalling Tailscale..."
    $uninstallString = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" |
    Where-Object { $_.DisplayName -match "tailscale" } |
    Select-Object -ExpandProperty UninstallString
    if ($uninstallString -match '\{[A-F0-9\-]+\}') {
        $guid = $matches[0]
        $msiArgs = @("/X", "`"$guid`"", "/quiet")
    } else {
        throw "Failed to get uninstallation string. Exiting..."
    }

    $result = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow
    if ($result.ExitCode -ne 0) {
        throw "Uninstallation failed with exit code: $($result.ExitCode)"
    }

    Write-Host "Cleaning up leftover files..."
    $cleanupPaths = @(
        $script:Config.InstallDir,
        (Join-Path $env:ProgramData 'Tailscale'),
        (Join-Path $env:LOCALAPPDATA 'Tailscale')
    )
    foreach ($path in $cleanupPaths) {
        if (Test-Path $path) {
            Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "Cleaned up $path"
        }
    }
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
            Uninstall-Tailscale
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