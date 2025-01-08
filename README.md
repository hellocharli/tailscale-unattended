# Tailscale PowerShell Installation Script

A PowerShell script to install or uninstall [Tailscale](https://tailscale.com/) on Windows using an MSI installer. The script automatically downloads the latest stable Tailscale MSI if none is found in the installation directory. It then installs Tailscale, authenticates using an [auth key](https://tailscale.com/kb/1085/auth-keys/), and optionally applies advertised tags.

## Features

- **Automated Download**: Fetches the latest Tailscale MSI installer automatically.
- **Simple Install & Uninstall**: One script can both install (`connect`) and uninstall (`disconnect`) Tailscale.
- **Supports Tags**: Pass any Tailscale tags you need. The script automatically prepends `tag:` if missing.
- **Configurable Defaults**: Optionally set a default `AuthKey` and `DefaultTags` in the configuration section at the top of the script.

## Requirements

- **Windows PowerShell 5.1** (or later), or **PowerShell 7+**.
- **Administrator Privileges**: The script must be run in an elevated PowerShell prompt.

## Usage

1. **Clone or download** this repository.
2. Open an **elevated** PowerShell prompt in the folder containing `tailscale.ps1`.
3. Run one of the following commands:

```powershell
# Show script usage
.\tailscale.ps1 help

# Install and connect to your Tailnet (with an auth key and optional tags)
.\tailscale.ps1 connect -AuthKey "tskey-abcdef123" -AdvertiseTags "eng","prod"

# Uninstall and remove Tailscale from your system
.\tailscale.ps1 disconnect
```

## Parameters
`-Command` (Positional)
- `connect` — Install Tailscale and authenticate to your Tailnet.
- `disconnect` — Uninstall Tailscale and remove it from your system.
- `help` — Show help.

`-AuthKey`
(Optional for connect, but if not supplied and no default is set in the script, you will be prompted for it.)

`-AdvertiseTags`
(Optional) An array of tags you want to advertise. Example: `"dev","prod"`.

`-Help`
Displays help information. Equivalent to `-Command help`.

## Customization
**Default AuthKey**: Update `AuthKey` in `$script:Config` at the top of the script if you want a hardcoded default.

**Default Tags**: Update `DefaultTags` in `$script:Config` if you commonly use the same tags.

**Installer Options**: Customize `MsiArgs` in `$script:Config` for different Tailscale MSI settings (for example, enabling or disabling certain Tailscale features).

## Contributing
Feel free to open issues or submit pull requests if you encounter any problems or have suggestions for improvements.

## License
This script is provided under the MIT License. You are free to use, modify, and distribute it.

## Disclaimer
This script is provided as-is with no warranty. Use at your own risk. Always review the script’s contents to ensure it meets your organization’s security and deployment requirements.