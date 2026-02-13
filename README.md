# Website-Blocker


PowerShell script to block websites on Windows using the hosts file and Windows Firewall.



## Features

- Blocks websites and common subdomains

- Supports comma-separated input for multiple sites

- Temporary access (default 1 minutes, configurable)

- Unblock individual sites or remove all blocks

- Refresh IPs for blocked sites

- Logs actions to `%USERPROFILE%\\Documents\\blocker.log`

- Backs up hosts file to `C:\\Windows\\System32\\drivers\\etc\\hosts.bak`



## Requirements

- Windows 10/11

- Run as Administrator


## Usage

1. Download the repository or the files.

2. Double-click `run.bat` (recommended — handles execution policy and launches the script).

&nbsp;  - Or right-click `WebsiteBlocker.ps1` → Run with PowerShell (it will prompt for admin if needed).

3. Follow the menu.



**Note**: The script modifies the system hosts file and firewall rules. A hosts backup is created automatically. Some antivirus software may flag PowerShell scripts run as admin.



## Customization

- Temporary access duration: edit `$TimerSeconds` (in seconds)

- Subdomains: edit `$SubdomainsBase` array



## Files

- `WebsiteBlocker.ps1` — main script

- `run.bat` — simple launcher (bypasses execution policy)

## License
MIT License — see the [LICENSE](LICENSE) file for details.



