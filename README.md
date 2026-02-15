# Website-Blocker

PowerShell script to block websites on Windows using dual-layer blocking (hosts file and Windows Firewall).

## Features

- Dual-layer blocking system (hosts file + firewall IP blocking)
- Blocks 40+ subdomain variants per site (www, mobile, API, CDN, auth, websocket endpoints)
- Supports comma-separated input for multiple sites
- Temporary access with countdown timer (default 1 minute, configurable)
- Press 'B' during timer to re-block early
- Unblock individual sites or remove all blocks
- Refresh IPs for blocked sites to maintain effectiveness
- Fast DNS resolution with 2-second timeout per query
- Comprehensive error handling and graceful degradation
- Logs actions to `%USERPROFILE%\Documents\blocker.log`
- Automatic hosts file backup to `C:\Windows\System32\drivers\etc\hosts.bak`

## What's New in v2.0

- **Performance**: 10-12x faster DNS resolution (5 seconds vs 60+ seconds per site)
- **Reliability**: Fixed missing `Generate-Subdomains` function that caused crashes
- **Coverage**: Enhanced subdomain list for better blocking of modern web apps
- **Stability**: Consistent UTF-8 file encoding, better regex parsing, improved error handling
- **UX**: Real-time countdown timer, clearer status messages, better menu display

## Requirements

- Windows 10/11
- PowerShell 5.1 or later
- Administrator privileges

## Usage

1. Download the repository or the files.

2. Run `run.bat` as Administrator (Ctrl+Shift+Click recommended — handles execution policy and launches the script).

   - Or right-click `website-blocker-fixed.ps1` → Run with PowerShell (it will prompt for admin if needed).

3. Follow the on-screen menu:
   - **Option 1**: Block new website(s)
   - **Option 2**: Temporary access (opens site for configurable duration)
   - **Option 3**: Permanently unblock a specific site
   - **Option 4**: Remove all blocks
   - **Option 5**: Refresh all blocks (update IPs)
   - **Option 6**: Help and information
   - **Option 7**: Exit

**Note**: The script modifies the system hosts file and firewall rules. A hosts backup is created automatically before any changes. Some antivirus software may flag PowerShell scripts that run with admin privileges or modify the hosts file.

## Examples

### Block a single site
```
Enter website(s) to block: reddit.com
```

### Block multiple sites at once
```
Enter website(s) to block: facebook.com, twitter.com, instagram.com
```

### Temporary access
```
1. Select option 2 from menu
2. Choose site number from blocked list
3. Site opens in browser for 60 seconds
4. Press 'B' and Enter to re-block early
5. Automatically re-blocks when timer expires
```

## Customization

### Change temporary access duration
Edit the `$TimerSeconds` variable at the top of the script:
```powershell
$TimerSeconds = 120  # 2 minutes instead of default 60 seconds
```

### Add custom subdomains
Edit the `$SubdomainsBase` array to include additional subdomain patterns:
```powershell
$SubdomainsBase = @(
    "", "www.", "m.", "mobile.",
    # ... existing entries ...
    "custom.", "special.", "your-subdomain."  # Add your own
)
```

### Change log file location
Edit the `$LogPath` variable:
```powershell
$LogPath = "C:\MyLogs\blocker.log"
```

## Known Issues and Limitations

### YouTube Blocking Side Effects
Blocking `youtube.com` may also affect:
- YouTube Music
- YouTube Kids
- Google AI Studio (uses YouTube infrastructure)
- Gemini (shares some Google domains)

**Workaround**: If you need these services, block specific YouTube subdomains instead of the entire domain, or use temporary access when needed.

### Sites May Still Be Accessible If:
- Browser is using DNS over HTTPS (DoH) — disable in browser settings
- VPN or proxy is active
- Browser cache contains old DNS entries — clear cache and restart browser
- Site uses alternative IP addresses not yet resolved

**Solution**: Run "Refresh All Blocks" (option 5) to update IPs, or manually flush DNS with `ipconfig /flushdns`.

### Firewall Rules May Not Persist
Windows updates or firewall resets can clear custom rules.

**Solution**: Run "Refresh All Blocks" after system updates or restarts.

## Troubleshooting

### "Access Denied" or "Not Running as Administrator"
Run PowerShell or `run.bat` as Administrator (right-click → Run as Administrator).

### Site Still Accessible After Blocking
1. Clear browser cache (Ctrl+Shift+Del)
2. Restart browser completely (close all windows)
3. Run `ipconfig /flushdns` in Command Prompt
4. Disable VPN/proxy if active
5. Disable DNS over HTTPS in browser settings
6. Run "Refresh All Blocks" (option 5) to update IPs

### Hosts File Won't Update
1. Check if antivirus is blocking hosts file changes (add exception if needed)
2. Manually remove read-only attribute: `attrib -r C:\Windows\System32\drivers\etc\hosts`
3. Verify you're running as Administrator

### DNS Resolution Fails
This is normal for non-existent domains. The script will still block via hosts file.

## How It Works

The script uses a two-layer approach for robust blocking:

1. **Hosts File Layer**
   - Redirects domain requests to localhost (127.0.0.1 for IPv4, ::1 for IPv6)
   - Covers 40+ subdomain variants per blocked site
   - Works at the OS level before DNS lookup

2. **Firewall Layer**
   - Resolves blocked domains to IP addresses
   - Creates Windows Firewall outbound rules to block traffic
   - Blocks up to 100 IPs per domain (Windows limit)
   - Provides redundancy if hosts file is bypassed

Both layers work together to ensure comprehensive blocking even if one method is circumvented.

## Files

- `website-blocker-fixed.ps1` — main script (v2.0 with all fixes)
- `run.bat` — simple launcher (bypasses execution policy)
- `FIXES-AND-IMPROVEMENTS.md` — detailed changelog and technical documentation
- `README.md` — this file

## Performance

| Operation | v1.0 (Original) | v2.0 (Fixed) | Improvement |
|-----------|----------------|--------------|-------------|
| Block 1 site | ~60 seconds | ~5 seconds | 12x faster |
| Block 5 sites | ~5 minutes | ~25 seconds | 12x faster |
| DNS timeout | 30+ seconds | 2 seconds | 15x faster |

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## License

MIT License — see the [LICENSE](LICENSE) file for details.

## Disclaimer

This tool is intended for personal productivity and parental control purposes. Use responsibly and in accordance with applicable laws and regulations. The authors are not responsible for misuse or any consequences resulting from the use of this software.
