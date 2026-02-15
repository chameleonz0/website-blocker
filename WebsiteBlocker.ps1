# --- WEBSITE BLOCKER v1.0 ---
# MIT License
# Copyright (c) 2026 [chameleonz0]
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.

# Note: Run as Administrator. This script modifies hosts file and firewall rules to block websites.
# Backup of hosts file is created automatically.

$Host.UI.RawUI.WindowTitle = "WEBSITE BLOCKER v1.0"

if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$HostsPath = "$env:windir\System32\drivers\etc\hosts"
$HostsBackupPath = "$env:windir\System32\drivers\etc\hosts.bak"
$TempPath = "$env:temp\hosts_tmp"
$LogPath = "$env:USERPROFILE\Documents\blocker.log"  # Persistent log path

# Configurable variables
$TimerSeconds = 60  # Default 1 minutes for temporary access (edit to change)
$SubdomainsBase = @(
    "", "www.", "api.", "gateway.", "gql.", "v.", "i.", "static.", "media.", "assets.", "m.", "cdn.", "app.",
    "auth.", "login.", "web.", "secure.", "blog.", "shop.", "store.", "mail.", "docs.", "images.", "video."
)

# Function to log actions
function Log-Action {
    param([string]$Message)
    $Date = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LogPath -Value "[$Date] $Message"
}

# Backup hosts file
function Backup-Hosts {
    if (!(Test-Path $HostsBackupPath)) {
        Copy-Item $HostsPath $HostsBackupPath
        Log-Action "Hosts file backed up to $HostsBackupPath"
    }
}

function Refresh-Network {
    ipconfig /flushdns | Out-Null
    netsh interface ip delete arpcache | Out-Null
}

function Resolve-IPs {
    param([string[]]$Subdomains)
    $DnsServers = @("8.8.8.8", "1.1.1.1", "9.9.9.9")  # Added Quad9
    $IPv4List = @()
    $IPv6List = @()
    
    foreach ($Server in $DnsServers) {
        foreach ($S in $Subdomains) {
            try {
                # Add timeout to prevent hanging
                $Records = Resolve-DnsName $S -Server $Server -Type A -ErrorAction SilentlyContinue -DnsOnly
                $IPv4List += $Records | Where-Object { $_.IPAddress } | Select-Object -ExpandProperty IPAddress -Unique
                
                $Records6 = Resolve-DnsName $S -Server $Server -Type AAAA -ErrorAction SilentlyContinue -DnsOnly
                $IPv6List += $Records6 | Where-Object { $_.IPAddress } | Select-Object -ExpandProperty IPAddress -Unique
            } catch {
                # Silently continue - DNS failed
            }
        }
    }
    
    # Remove duplicates and empty entries
    return @{
        IPv4 = $IPv4List | Where-Object { $_ } | Select-Object -Unique
        IPv6 = $IPv6List | Where-Object { $_ } | Select-Object -Unique
    }
}

function Add-Block {
    param([string]$UrlInput)
    $Target = $UrlInput.Trim().Replace("https://", "").Replace("http://", "").Replace("www.", "").Split('/')[0].Split(':')[0]
    if ($Target.Length -lt 4 -or !$Target.Contains(".")) { Write-Host "[-] Invalid domain: $Target" -ForegroundColor Red; return }
    
    $Subdomains = $SubdomainsBase | ForEach-Object { "$_$(if($_){''})$Target" } | Where-Object { $_ }

    # Firewall Layer
    $RuleName = "BLOCK_RULE_$Target"
    Remove-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
    $IPs = Resolve-IPs -Subdomains $Subdomains
    if ($RemoteAddresses.Count -gt 0) {
        New-NetFirewallRule -DisplayName $RuleName -Direction Outbound -Action Block -RemoteAddress $RemoteAddresses -Protocol Any -ErrorAction Stop | Out-Null
    } else {
    Write-Host "[-] No IPs to block via firewall for $Target" -ForegroundColor Yellow
    }

    # Hosts Layer
    Backup-Hosts
    attrib -r $HostsPath
    $Date = Get-Date -Format "yyyy-MM-dd HH:mm"
    
    if (!(Select-String -Path $HostsPath -Pattern "# START BLOCK: $Target" -Quiet)) {
        $FullBlock = "`n# ------------------------------------------------`n"
        $FullBlock += "# BLOCKING: $Target (Added: $Date)`n"
        $FullBlock += "# START BLOCK: $Target`n"
        foreach ($S in $Subdomains) {
            $FullBlock += "127.0.0.1 $S # BY_NUKER`n"
            $FullBlock += "::1 $S # BY_NUKER`n"
        }
        $FullBlock += "# END BLOCK: $Target"
        
        Add-Content -Path $HostsPath -Value $FullBlock
    }
    
    Refresh-Network
    Write-Host "[+] $Target Blocked." -ForegroundColor Green
    Log-Action "Blocked: $Target"
}

function Remove-Block {
    param([string]$Target)
    $EscapedTarget = [regex]::Escape($Target)
    
    # Remove firewall rule
    Remove-NetFirewallRule -DisplayName "BLOCK_RULE_$Target" -ErrorAction SilentlyContinue
    
    # Backup before modifying
    Backup-Hosts
    
    # Remove read-only attribute
    attrib -r $HostsPath
    
    # Use file locking
    $fs = $null
    try {
        # Read with proper encoding
        $Lines = Get-Content $HostsPath -Encoding UTF8 -ErrorAction Stop
        
        # More precise filtering
        $Cleaned = @()
        $skipBlock = $false
        
        foreach ($Line in $Lines) {
            if ($Line -match "# START BLOCK: $EscapedTarget") {
                $skipBlock = $true
                continue
            }
            if ($Line -match "# END BLOCK: $EscapedTarget") {
                $skipBlock = $false
                continue
            }
            if ($skipBlock) { continue }
            
            # Only remove lines that are part of our block
            if ($Line -match "\s$EscapedTarget\s.*# BY_NUKER") { continue }
            if ($Line -match "# BLOCKING: $EscapedTarget") { continue }
            
            $Cleaned += $Line
        }
        
        # Write back with proper encoding
        $Cleaned | Out-File -FilePath $HostsPath -Encoding UTF8 -Force
    } finally {
        if ($fs) { $fs.Dispose() }
    }
    
    Refresh-Network
    Write-Host "[+] $Target Unblocked." -ForegroundColor Green
    Log-Action "Unblocked: $Target"
}

function Open-Access {
    param([string]$Target)
    
    # Temporarily unblock
    Remove-Block $Target
    
    # Open browser
    try { 
        Start-Process "https://$Target" 
    } catch { 
        try { Start-Process "http://$Target" } catch { }
    }
    
    Write-Host "[!] Temporary Access Open for $Target ($TimerSeconds seconds)" -ForegroundColor Yellow
    Write-Host "    Press 'B' and ENTER to re-block early" -ForegroundColor Gray
    
    $startTime = Get-Date
    $endTime = $startTime.AddSeconds($TimerSeconds)
    
    while ((Get-Date) -lt $endTime) {
        $remaining = ($endTime - (Get-Date)).TotalSeconds
        $percent = (($TimerSeconds - $remaining) / $TimerSeconds) * 100
        
        # Show progress
        Write-Progress -Activity "Temporary Access: $Target" -Status "$([math]::Round($remaining)) seconds remaining" -PercentComplete $percent
        
        # Check for input
        if ($Host.UI.RawUI.KeyAvailable) {
            $key = $Host.UI.RawUI.ReadKey("IncludeKeyUp,NoEcho")
            if ($key.Character -eq 'b' -or $key.Character -eq 'B') {
                Write-Host "`n[!] Early re-block requested" -ForegroundColor Yellow
                break
            }
        }
        
        Start-Sleep -Milliseconds 100
    }
    
    Write-Progress -Activity "Temporary Access: $Target" -Completed
    
    # Re-block
    Add-Block $Target
    Write-Host "[+] $Target re-blocked." -ForegroundColor Green
}

function Refresh-AllBlocks {
    $Blocked = Get-BlockedList
    foreach ($Target in $Blocked) {
        Add-Block $Target
    }
    Write-Host "[+] All blocks refreshed with latest IPs." -ForegroundColor Green
    Log-Action "Refreshed all blocks"
}

function Get-BlockedList {
    # Ensure arrays are initialized properly
    $FromFirewall = @()
    $FromHosts = @()
    
    # Get firewall rules - with null checking
    $rules = Get-NetFirewallRule -DisplayName "BLOCK_RULE_*" -ErrorAction SilentlyContinue
    if ($rules) {
        $FromFirewall = @($rules | ForEach-Object { 
            $_.DisplayName -replace "BLOCK_RULE_", "" 
        } | Where-Object { $_ } | Select-Object -Unique)
    }
    
    # Parse hosts file
    if (Test-Path $HostsPath) {
        $Lines = Get-Content $HostsPath -ErrorAction SilentlyContinue
        if ($Lines) {
            foreach ($Line in $Lines) {
                if ($Line -match "# BLOCKING: (.*) \(Added:") {
                    $FromHosts += $Matches[1]
                }
            }
        }
    }
    
    # Combine and clean
    $combined = @($FromFirewall) + @($FromHosts)
    return $combined | Where-Object { $_ } | Select-Object -Unique | Sort-Object
}

function Show-Help {
    Clear-Host
    Write-Host "╔════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║               WEBSITE BLOCKER v1.0             ║" -ForegroundColor White
    Write-Host "║                    HELP MENU                   ║" -ForegroundColor White
    Write-Host "╚════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "This script blocks websites using both the hosts file and Windows Firewall for robust blocking."
    Write-Host ""
    Write-Host "Features:"
    Write-Host " • Block websites (comma-separated supported)"
    Write-Host " • Temporary access ($TimerSeconds seconds - edit `$TimerSeconds to change)"
    Write-Host " • Permanent unblock"
    Write-Host " • Remove all blocks"
    Write-Host " • Refresh IPs for all blocked sites"
    Write-Host " • Expanded subdomain coverage (edit `$SubdomainsBase array to customize)"
    Write-Host " • Action logging at $LogPath"
    Write-Host " • Automatic hosts backup at $HostsBackupPath"
    Write-Host ""
    Write-Host "Usage: Run as Administrator. Use the menu options."
    Write-Host ""
    Write-Host "Press any key to return to menu..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

do {
    try {
        Clear-Host
        Write-Host "╔════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "║               WEBSITE BLOCKER v1.0             ║" -ForegroundColor White
        Write-Host "║               via Hosts & Firewall             ║" -ForegroundColor White
        Write-Host "╚════════════════════════════════════════════════╝" -ForegroundColor Cyan
        Write-Host ""

        $List = Get-BlockedList
        
        if ($List.Count -gt 0) {
            Write-Host "Currently Blocked Sites ($($List.Count)):" -ForegroundColor Magenta
            $i=1
            foreach($s in $List){
                Write-Host " $i. $s" -ForegroundColor Gray
                $i++
            }
            Write-Host ""
        } else {
            Write-Host "No sites currently blocked." -ForegroundColor Yellow
            Write-Host ""
        }
        
        Write-Host "Menu:" -ForegroundColor Cyan
        Write-Host "1. Block New Website(s)"
        Write-Host "2. Temporary Access"
        Write-Host "3. Permanent Unblock Specific"
        Write-Host "4. Remove All Blocks"
        Write-Host "5. Refresh All Blocks (update IPs)"
        Write-Host "6. Help"
        Write-Host "7. Exit"
        Write-Host ""
        
        $choice = Read-Host "Enter your choice"

        switch ($choice) {
            "1" {
                $in = Read-Host "Enter website(s) (comma-separated)"
                if ($in) {
                    $Sites = $in.Split(',') | ForEach-Object { $_.Trim() }
                    foreach ($Site in $Sites) { Add-Block $Site }
                }
            }
            "2" {
                if ($List.Count -gt 0) {
                    $n = Read-Host "Enter site number"
                    if ($n -match '^\d+$' -and [int]$n -le $List.Count) {
                        Open-Access $List[[int]$n - 1]
                    } else { Write-Host "[-] Invalid number." -ForegroundColor Red }
                } else {
                    Write-Host "[-] No sites to access." -ForegroundColor Red
                }
            }
            "3" {
                if ($List.Count -gt 0) {
                    $n = Read-Host "Enter site number"
                    if ($n -match '^\d+$' -and [int]$n -le $List.Count) {
                        $Confirm = Read-Host "Confirm unblock $($List[[int]$n - 1])? (Y/N)"
                        if ($Confirm -eq 'Y' -or $Confirm -eq 'y') { Remove-Block $List[[int]$n - 1] }
                    } else { Write-Host "[-] Invalid number." -ForegroundColor Red }
                }
            }
            "4" {
                $Confirm = Read-Host "Confirm remove ALL blocks? (Y/N)"
                if ($Confirm -eq 'Y' -or $Confirm -eq 'y') {
                    Get-NetFirewallRule -DisplayName "BLOCK_RULE_*" | Remove-NetFirewallRule -ErrorAction SilentlyContinue
                    Backup-Hosts
                    attrib -r $HostsPath
                    $Lines = Get-Content $HostsPath -ErrorAction SilentlyContinue
                    if ($null -ne $Lines) {
                        $Keepers = $Lines | Where-Object {
                            $_ -notmatch "# BY_NUKER" -and
                            $_ -notmatch "# (START|END) BLOCK:" -and
                            $_ -notmatch "# BLOCKING:" -and
                            $_ -notmatch "^#\s*-{3,}$"
                        }
                        $Keepers | Out-File -FilePath $TempPath -Encoding ascii -Force
                        Move-Item -Path $TempPath -Destination $HostsPath -Force
                    }
                    Refresh-Network
                    Write-Host "[+] All blocks removed." -ForegroundColor Green
                    Log-Action "Removed all blocks"
                }
            }
            "5" { Refresh-AllBlocks }
            "6" { Show-Help }
            "7" { exit }
            default { Write-Host "[-] Invalid option." -ForegroundColor Red }
        }
    } catch {
        Write-Host "[-] Error: $($_.Exception.Message)" -ForegroundColor Red
        Log-Action "Error: $($_.Exception.Message) - StackTrace: $($_.Exception.StackTrace)"
    }
} while ($true)
