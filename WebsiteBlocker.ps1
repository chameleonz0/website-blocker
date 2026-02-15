# --- WEBSITE BLOCKER v2.0 ---
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

$Host.UI.RawUI.WindowTitle = "WEBSITE BLOCKER v2.0"

# Check admin privileges
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# File paths
$HostsPath = "$env:windir\System32\drivers\etc\hosts"
$HostsBackupPath = "$env:windir\System32\drivers\etc\hosts.bak"
$TempPath = "$env:temp\hosts_tmp"
$LogPath = "$env:USERPROFILE\Documents\blocker.log"

# Verify log path is writable
try {
    "`n" | Out-File -FilePath $LogPath -Append -ErrorAction Stop
} catch {
    $LogPath = "$env:TEMP\blocker.log"
    Write-Host "[!] Using fallback log location: $LogPath" -ForegroundColor Yellow
}

# Configurable variables
$TimerSeconds = 60  # Default 1 minute for temporary access
$SubdomainsBase = @(
    "", "www.", "m.", "mobile.", 
    "api.", "api-v1.", "api-v2.", "gateway.", "gql.", "graphql.",
    "cdn.", "cdn1.", "cdn2.", "cdn3.", "static.", "assets.", "media.", "images.", "img.", "video.",
    "app.", "web.", "client.", "portal.",
    "auth.", "login.", "oauth.", "accounts.", "sso.",
    "ws.", "websocket.", "wss.",
    "edge.", "edge-chat.",
    "secure.", "safe.",
    "mail.", "email.",
    "docs.", "help.", "support.",
    "blog.", "news.",
    "shop.", "store.", "checkout.", "cart.",
    "upload.", "download.",
    "dev.", "staging.", "beta.", "alpha."
)

# Performance optimizations
$PSDefaultParameterValues['*:ErrorAction'] = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Log-Action {
    param([string]$Message)
    try {
        $Date = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content -Path $LogPath -Value "[$Date] $Message" -ErrorAction Stop
    } catch {
        # Silently fail logging if can't write
    }
}

function Backup-Hosts {
    if (!(Test-Path $HostsBackupPath)) {
        Copy-Item $HostsPath $HostsBackupPath -Force
        Log-Action "Hosts file backed up to $HostsBackupPath"
    }
}

function Refresh-Network {
    try {
        ipconfig /flushdns | Out-Null
        Start-Sleep -Milliseconds 100
    } catch {
        Write-Host "[-] Failed to flush DNS" -ForegroundColor Yellow
    }
}

function Test-ValidDomain {
    param([string]$Domain)
    
    if ([string]::IsNullOrWhiteSpace($Domain)) { return $false }
    if ($Domain.Length -lt 4 -or $Domain.Length -gt 253) { return $false }
    if ($Domain -match "[^a-zA-Z0-9\.\-]") { return $false }
    if (-not $Domain.Contains(".")) { return $false }
    if ($Domain.StartsWith(".") -or $Domain.EndsWith(".")) { return $false }
    if ($Domain.Contains("..")) { return $false }
    
    return $true
}

function Generate-Subdomains {
    param([string]$Domain)
    
    $Subdomains = @()
    
    # Add base domain and www
    $Subdomains += $Domain
    $Subdomains += "www.$Domain"
    
    # Add all subdomain prefixes
    foreach ($Prefix in $SubdomainsBase) {
        if ($Prefix -eq "" -or $Prefix -eq "www.") { continue }  # Already added
        $Subdomains += "$Prefix$Domain"
    }
    
    # Add wildcard patterns for hosts file (some browsers respect these)
    $Subdomains += "*.$Domain"
    
    return $Subdomains | Select-Object -Unique
}

function Resolve-IPs-Fast {
    param([string[]]$Subdomains)
    
    $AllIPs = @()
    $MaxConcurrent = 5
    $TimeoutMs = 2000  # 2 second timeout per query
    
    # Only query the main domain and www subdomain (much faster)
    $PrioritySubdomains = $Subdomains | Where-Object { 
        $_ -notmatch "^\*\." -and ($_ -eq $Subdomains[0] -or $_ -like "www.*")
    } | Select-Object -First 3
    
    foreach ($Subdomain in $PrioritySubdomains) {
        try {
            # Use Resolve-DnsName with timeout
            $Job = Start-Job -ScriptBlock {
                param($domain)
                try {
                    $results = @()
                    $a = Resolve-DnsName $domain -Type A -ErrorAction Stop -DnsOnly
                    $results += $a | Where-Object { $_.IPAddress } | Select-Object -ExpandProperty IPAddress
                    $aaaa = Resolve-DnsName $domain -Type AAAA -ErrorAction Stop -DnsOnly
                    $results += $aaaa | Where-Object { $_.IPAddress } | Select-Object -ExpandProperty IPAddress
                    return $results
                } catch {
                    return @()
                }
            } -ArgumentList $Subdomain
            
            # Wait with timeout
            $Completed = Wait-Job $Job -Timeout ($TimeoutMs / 1000)
            
            if ($Completed) {
                $Result = Receive-Job $Job
                if ($Result) {
                    $AllIPs += $Result
                }
            }
            
            Remove-Job $Job -Force
            
        } catch {
            # Skip failed lookups
            continue
        }
    }
    
    return $AllIPs | Where-Object { $_ } | Select-Object -Unique
}

# ============================================================================
# CORE BLOCKING FUNCTIONS
# ============================================================================

function Add-Block {
    param([string]$UrlInput)
    
    # Input validation and cleanup
    $Target = $UrlInput.Trim() -replace '^https?://', '' -replace '^www\.', '' -replace '[/:].*$', ''
    
    if (-not (Test-ValidDomain $Target)) {
        Write-Host "[-] Invalid domain: $Target" -ForegroundColor Red
        return
    }
    
    Write-Host "[*] Blocking $Target..." -ForegroundColor Yellow
    
    # Generate subdomains
    $Subdomains = Generate-Subdomains -Domain $Target
    Write-Host "[*] Generated $($Subdomains.Count) subdomain variants" -ForegroundColor Gray
    
    # ========== FIREWALL LAYER ==========
    $RuleName = "WebBlock_$($Target.Replace('.', '_'))"
    
    try {
        # Remove existing rule if present
        Remove-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
        
        # Resolve IPs (fast method)
        Write-Host "[*] Resolving IP addresses..." -ForegroundColor Gray
        $IPs = Resolve-IPs-Fast -Subdomains $Subdomains
        
        if ($IPs.Count -gt 0) {
            # Windows Firewall has a limit of ~1000 IPs per rule, so we limit it
            $IPsToBlock = $IPs | Select-Object -First 100 -Unique
            
            New-NetFirewallRule -DisplayName $RuleName `
                -Direction Outbound `
                -Action Block `
                -RemoteAddress $IPsToBlock `
                -Protocol Any `
                -ErrorAction Stop | Out-Null
            
            Write-Host "[+] Firewall: Blocked $($IPsToBlock.Count) IP addresses" -ForegroundColor Green
        } else {
            Write-Host "[!] Firewall: No IPs resolved (using hosts file only)" -ForegroundColor Yellow
        }
        
    } catch {
        Write-Host "[!] Firewall rule failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Log-Action "Firewall error for ${Target}: $($_.Exception.Message)"
    }
    
    # ========== HOSTS FILE LAYER ==========
    try {
        Backup-Hosts
        
        # Remove read-only attribute
        Set-ItemProperty -Path $HostsPath -Name IsReadOnly -Value $false
        
        # Check if already blocked
        $HostsContent = Get-Content $HostsPath -Raw -ErrorAction Stop
        
        if ($HostsContent -match "# START_BLOCK: $([regex]::Escape($Target))") {
            Write-Host "[!] Hosts: Already blocked" -ForegroundColor Yellow
        } else {
            $Date = Get-Date -Format "yyyy-MM-dd HH:mm"
            
            # Build the block
            $BlockLines = @()
            $BlockLines += ""
            $BlockLines += "# ================================================"
            $BlockLines += "# BLOCKED: $Target (Added: $Date)"
            $BlockLines += "# START_BLOCK: $Target"
            
            foreach ($Sub in $Subdomains) {
                if ($Sub -notmatch "^\*\.") {  # Skip wildcard entries for hosts
                    $BlockLines += "127.0.0.1 $Sub"
                    $BlockLines += "::1 $Sub"
                }
            }
            
            $BlockLines += "# END_BLOCK: $Target"
            $BlockLines += "# ================================================"
            
            # Append to hosts file
            $BlockLines | Out-File -FilePath $HostsPath -Append -Encoding UTF8 -Force
            
            Write-Host "[+] Hosts: Added $($Subdomains.Count) entries" -ForegroundColor Green
        }
        
        # Restore read-only
        Set-ItemProperty -Path $HostsPath -Name IsReadOnly -Value $true
        
    } catch {
        Write-Host "[!] Hosts file failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Log-Action "Hosts error for ${Target}: $($_.Exception.Message)"
    }
    
    # Refresh network
    Refresh-Network
    
    Write-Host ""
    Write-Host "[✓] $Target is now BLOCKED" -ForegroundColor Green -BackgroundColor DarkGreen
    Write-Host ""
    Log-Action "Blocked: $Target"
    
    Start-Sleep -Seconds 1
}

function Remove-Block {
    param([string]$Target)
    
    Write-Host "[*] Unblocking $Target..." -ForegroundColor Yellow
    
    # ========== REMOVE FIREWALL RULE ==========
    $RuleName = "WebBlock_$($Target.Replace('.', '_'))"
    try {
        Remove-NetFirewallRule -DisplayName $RuleName -ErrorAction Stop
        Write-Host "[+] Firewall rule removed" -ForegroundColor Green
    } catch {
        # Rule might not exist
    }
    
    # ========== REMOVE FROM HOSTS FILE ==========
    try {
        Backup-Hosts
        
        # Remove read-only
        Set-ItemProperty -Path $HostsPath -Name IsReadOnly -Value $false
        
        # Read all lines
        $AllLines = Get-Content $HostsPath -ErrorAction Stop
        
        # Filter out the block
        $NewLines = @()
        $InBlock = $false
        $EscapedTarget = [regex]::Escape($Target)
        
        foreach ($Line in $AllLines) {
            if ($Line -match "^# START_BLOCK: $EscapedTarget\s*$") {
                $InBlock = $true
                continue
            }
            
            if ($Line -match "^# END_BLOCK: $EscapedTarget\s*$") {
                $InBlock = $false
                continue
            }
            
            # Skip lines in block
            if ($InBlock) {
                continue
            }
            
            # Skip header/separator lines for this domain
            if ($Line -match "^# BLOCKED: $EscapedTarget") {
                continue
            }
            
            if ($Line -match "^# ={20,}\s*$") {
                # Check if previous line was domain-specific
                if ($NewLines.Count -gt 0 -and $NewLines[-1] -match "BLOCKED: $EscapedTarget") {
                    continue
                }
            }
            
            $NewLines += $Line
        }
        
        # Write back
        $NewLines | Out-File -FilePath $HostsPath -Encoding UTF8 -Force
        
        Write-Host "[+] Hosts entries removed" -ForegroundColor Green
        
        # Restore read-only
        Set-ItemProperty -Path $HostsPath -Name IsReadOnly -Value $true
        
    } catch {
        Write-Host "[!] Hosts file error: $($_.Exception.Message)" -ForegroundColor Yellow
        Log-Action "Unblock error for ${Target}: $($_.Exception.Message)"
    }
    
    Refresh-Network
    
    Write-Host ""
    Write-Host "[✓] $Target is now UNBLOCKED" -ForegroundColor Green -BackgroundColor DarkGreen
    Write-Host ""
    Log-Action "Unblocked: $Target"
    
    Start-Sleep -Seconds 1
}

function Open-Access {
    param([string]$Target)
    
    Write-Host ""
    Write-Host "════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  TEMPORARY ACCESS MODE" -ForegroundColor White
    Write-Host "════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    
    # Temporarily unblock
    Remove-Block $Target
    
    # Open browser
    Write-Host "[*] Opening browser..." -ForegroundColor Gray
    try { 
        Start-Process "https://$Target" 
    } catch { 
        try { 
            Start-Process "http://$Target" 
        } catch {
            Write-Host "[!] Could not open browser automatically" -ForegroundColor Yellow
        }
    }
    
    Write-Host ""
    Write-Host "[!] $Target is temporarily accessible" -ForegroundColor Yellow
    Write-Host "    Timer: $TimerSeconds seconds" -ForegroundColor Gray
    Write-Host "    Press 'B' + ENTER to re-block immediately" -ForegroundColor Gray
    Write-Host ""
    
    $StartTime = Get-Date
    $EndTime = $StartTime.AddSeconds($TimerSeconds)
    
    # Timer loop
    while ((Get-Date) -lt $EndTime) {
        $Remaining = [math]::Ceiling(($EndTime - (Get-Date)).TotalSeconds)
        
        if ($Remaining -le 0) { break }
        
        # Show countdown
        Write-Host "`r[TIMER] $Remaining seconds remaining...     " -NoNewline -ForegroundColor Yellow
        
        # Check for 'B' key (non-blocking)
        if ([Console]::KeyAvailable) {
            $Key = [Console]::ReadKey($true)
            if ($Key.Key -eq 'B') {
                Write-Host "`n"
                Write-Host "[!] Early re-block triggered by user" -ForegroundColor Yellow
                break
            }
        }
        
        Start-Sleep -Milliseconds 500
    }
    
    Write-Host "`n"
    
    # Re-block
    Add-Block $Target
}

function Get-BlockedList {
    $BlockedSites = @()
    
    # Parse hosts file
    if (Test-Path $HostsPath) {
        try {
            $Lines = Get-Content $HostsPath -ErrorAction Stop
            foreach ($Line in $Lines) {
                if ($Line -match "^# BLOCKED: (.+?) \(Added:") {
                    $BlockedSites += $Matches[1]
                }
            }
        } catch {
            Write-Host "[!] Could not read hosts file" -ForegroundColor Yellow
        }
    }
    
    return $BlockedSites | Select-Object -Unique | Sort-Object
}

function Refresh-AllBlocks {
    Write-Host "[*] Refreshing all blocks..." -ForegroundColor Yellow
    Write-Host ""
    
    $Blocked = Get-BlockedList
    
    if ($Blocked.Count -eq 0) {
        Write-Host "[!] No sites to refresh" -ForegroundColor Yellow
        return
    }
    
    $Count = 0
    foreach ($Target in $Blocked) {
        $Count++
        Write-Host "[$Count/$($Blocked.Count)] Refreshing: $Target" -ForegroundColor Gray
        
        # Remove old firewall rule
        $RuleName = "WebBlock_$($Target.Replace('.', '_'))"
        Remove-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
        
        # Re-add with fresh IPs
        $Subdomains = Generate-Subdomains -Domain $Target
        $IPs = Resolve-IPs-Fast -Subdomains $Subdomains
        
        if ($IPs.Count -gt 0) {
            $IPsToBlock = $IPs | Select-Object -First 100 -Unique
            try {
                New-NetFirewallRule -DisplayName $RuleName `
                    -Direction Outbound `
                    -Action Block `
                    -RemoteAddress $IPsToBlock `
                    -Protocol Any `
                    -ErrorAction Stop | Out-Null
                Write-Host "    → Updated with $($IPsToBlock.Count) IPs" -ForegroundColor Green
            } catch {
                Write-Host "    → Firewall update failed" -ForegroundColor Yellow
            }
        }
    }
    
    Write-Host ""
    Write-Host "[✓] All blocks refreshed" -ForegroundColor Green
    Log-Action "Refreshed all blocks"
    Start-Sleep -Seconds 2
}

function Remove-AllBlocks {
    Write-Host "[!] This will remove ALL blocks!" -ForegroundColor Red
    $Confirm = Read-Host "Type 'DELETE' to confirm"
    
    if ($Confirm -ne 'DELETE') {
        Write-Host "[*] Cancelled" -ForegroundColor Gray
        return
    }
    
    Write-Host ""
    Write-Host "[*] Removing all blocks..." -ForegroundColor Yellow
    
    # Remove all firewall rules
    try {
        $Rules = Get-NetFirewallRule -DisplayName "WebBlock_*" -ErrorAction SilentlyContinue
        if ($Rules) {
            $Rules | Remove-NetFirewallRule -ErrorAction SilentlyContinue
            Write-Host "[+] Removed $($Rules.Count) firewall rules" -ForegroundColor Green
        }
    } catch {
        Write-Host "[!] Firewall cleanup error" -ForegroundColor Yellow
    }
    
    # Clean hosts file
    try {
        Backup-Hosts
        Set-ItemProperty -Path $HostsPath -Name IsReadOnly -Value $false
        
        $AllLines = Get-Content $HostsPath -ErrorAction Stop
        $CleanLines = @()
        $InBlock = $false
        
        foreach ($Line in $AllLines) {
            if ($Line -match "^# START_BLOCK:") {
                $InBlock = $true
                continue
            }
            if ($Line -match "^# END_BLOCK:") {
                $InBlock = $false
                continue
            }
            if ($InBlock) { continue }
            if ($Line -match "^# BLOCKED:") { continue }
            if ($Line -match "^# ={20,}") { continue }
            
            $CleanLines += $Line
        }
        
        $CleanLines | Out-File -FilePath $HostsPath -Encoding UTF8 -Force
        Set-ItemProperty -Path $HostsPath -Name IsReadOnly -Value $true
        
        Write-Host "[+] Hosts file cleaned" -ForegroundColor Green
        
    } catch {
        Write-Host "[!] Hosts file cleanup error: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    
    Refresh-Network
    
    Write-Host ""
    Write-Host "[✓] All blocks removed" -ForegroundColor Green
    Log-Action "Removed all blocks"
    Start-Sleep -Seconds 2
}

function Show-Help {
    Clear-Host
    Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║            WEBSITE BLOCKER v2.0 - HELP               ║" -ForegroundColor White
    Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "WHAT'S FIXED IN v2.0:" -ForegroundColor Yellow
    Write-Host " • Much faster DNS resolution (2 second timeout)" -ForegroundColor Gray
    Write-Host " • Missing Generate-Subdomains function added" -ForegroundColor Gray
    Write-Host " • Better subdomain coverage (CDNs, APIs, etc.)" -ForegroundColor Gray
    Write-Host " • Fixed file encoding issues" -ForegroundColor Gray
    Write-Host " • More reliable hosts file parsing" -ForegroundColor Gray
    Write-Host " • Better error handling" -ForegroundColor Gray
    Write-Host " • Fixed firewall rule naming conflicts" -ForegroundColor Gray
    Write-Host ""
    Write-Host "HOW IT WORKS:" -ForegroundColor Yellow
    Write-Host " This script uses TWO blocking layers:" -ForegroundColor White
    Write-Host " 1. Windows Firewall - Blocks IP addresses" -ForegroundColor Gray
    Write-Host " 2. Hosts File - Redirects domains to localhost" -ForegroundColor Gray
    Write-Host ""
    Write-Host "FEATURES:" -ForegroundColor Yellow
    Write-Host " • Block multiple sites at once (comma-separated)" -ForegroundColor Gray
    Write-Host " • Temporary access with countdown timer" -ForegroundColor Gray
    Write-Host " • Press 'B' during timer to re-block early" -ForegroundColor Gray
    Write-Host " • Refresh blocks to update IPs" -ForegroundColor Gray
    Write-Host " • Comprehensive subdomain blocking" -ForegroundColor Gray
    Write-Host " • Automatic hosts file backup" -ForegroundColor Gray
    Write-Host " • Action logging" -ForegroundColor Gray
    Write-Host ""
    Write-Host "CONFIGURATION:" -ForegroundColor Yellow
    Write-Host " • Timer duration: Edit `$TimerSeconds variable" -ForegroundColor Gray
    Write-Host " • Subdomains: Edit `$SubdomainsBase array" -ForegroundColor Gray
    Write-Host " • Log location: $LogPath" -ForegroundColor Gray
    Write-Host ""
    Write-Host "TIPS:" -ForegroundColor Yellow
    Write-Host " • Run as Administrator (required)" -ForegroundColor Gray
    Write-Host " • Some sites may need 'Refresh All Blocks' periodically" -ForegroundColor Gray
    Write-Host " • If blocking fails, check the log file" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Press any key to return to menu..." -ForegroundColor Cyan
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# ============================================================================
# MAIN MENU LOOP
# ============================================================================

do {
    try {
        Clear-Host
        Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "║            WEBSITE BLOCKER v2.0 (Fixed)              ║" -ForegroundColor White
        Write-Host "║          Dual-Layer Blocking (Hosts + Firewall)      ║" -ForegroundColor White
        Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
        Write-Host ""

        # Get and display blocked sites
        $BlockedList = Get-BlockedList
        
        if ($BlockedList.Count -gt 0) {
            Write-Host "Currently Blocked ($($BlockedList.Count) sites):" -ForegroundColor Magenta
            Write-Host "─────────────────────────────────────────────────────" -ForegroundColor DarkGray
            
            $DisplayCount = [Math]::Min(15, $BlockedList.Count)
            for ($i = 0; $i -lt $DisplayCount; $i++) {
                Write-Host " $($i+1). $($BlockedList[$i])" -ForegroundColor Gray
            }
            
            if ($BlockedList.Count -gt 15) {
                Write-Host " ... and $($BlockedList.Count - 15) more" -ForegroundColor DarkGray
            }
            
            Write-Host ""
        } else {
            Write-Host "No sites currently blocked." -ForegroundColor Yellow
            Write-Host ""
        }
        
        Write-Host "═══════════════════ MENU ═══════════════════" -ForegroundColor Cyan
        Write-Host ""
        Write-Host " 1. Block New Website(s)" -ForegroundColor White
        Write-Host " 2. Temporary Access (timer)" -ForegroundColor White
        Write-Host " 3. Permanently Unblock Site" -ForegroundColor White
        Write-Host " 4. Remove ALL Blocks" -ForegroundColor White
        Write-Host " 5. Refresh All Blocks (update IPs)" -ForegroundColor White
        Write-Host " 6. Help & Info" -ForegroundColor White
        Write-Host " 7. Exit" -ForegroundColor White
        Write-Host ""
        Write-Host "════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host ""
        
        $Choice = Read-Host "Enter your choice (1-7)"
        Write-Host ""

        switch ($Choice) {
            "1" {
                $Input = Read-Host "Enter website(s) to block (comma-separated for multiple)"
                if ($Input) {
                    $Sites = $Input.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
                    foreach ($Site in $Sites) {
                        Add-Block $Site
                    }
                } else {
                    Write-Host "[-] No input provided" -ForegroundColor Red
                    Start-Sleep -Seconds 1
                }
            }
            
            "2" {
                if ($BlockedList.Count -eq 0) {
                    Write-Host "[-] No sites are currently blocked" -ForegroundColor Red
                    Start-Sleep -Seconds 2
                } else {
                    $Number = Read-Host "Enter site number (1-$($BlockedList.Count))"
                    if ($Number -match '^\d+$' -and [int]$Number -ge 1 -and [int]$Number -le $BlockedList.Count) {
                        $SelectedSite = $BlockedList[[int]$Number - 1]
                        Open-Access $SelectedSite
                    } else {
                        Write-Host "[-] Invalid number" -ForegroundColor Red
                        Start-Sleep -Seconds 1
                    }
                }
            }
            
            "3" {
                if ($BlockedList.Count -eq 0) {
                    Write-Host "[-] No sites are currently blocked" -ForegroundColor Red
                    Start-Sleep -Seconds 2
                } else {
                    $Number = Read-Host "Enter site number to unblock (1-$($BlockedList.Count))"
                    if ($Number -match '^\d+$' -and [int]$Number -ge 1 -and [int]$Number -le $BlockedList.Count) {
                        $SelectedSite = $BlockedList[[int]$Number - 1]
                        $Confirm = Read-Host "Permanently unblock '$SelectedSite'? (Y/N)"
                        if ($Confirm -eq 'Y' -or $Confirm -eq 'y') {
                            Remove-Block $SelectedSite
                        } else {
                            Write-Host "[*] Cancelled" -ForegroundColor Gray
                            Start-Sleep -Seconds 1
                        }
                    } else {
                        Write-Host "[-] Invalid number" -ForegroundColor Red
                        Start-Sleep -Seconds 1
                    }
                }
            }
            
            "4" {
                Remove-AllBlocks
            }
            
            "5" {
                Refresh-AllBlocks
            }
            
            "6" {
                Show-Help
            }
            
            "7" {
                Write-Host "[*] Exiting..." -ForegroundColor Gray
                exit
            }
            
            default {
                Write-Host "[-] Invalid option. Please enter 1-7" -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
        
    } catch {
        Write-Host ""
        Write-Host "═══════════════════════════════════════════" -ForegroundColor Red
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "═══════════════════════════════════════════" -ForegroundColor Red
        Write-Host ""
        Log-Action "CRITICAL ERROR: $($_.Exception.Message) | StackTrace: $($_.ScriptStackTrace)"
        Write-Host "Press any key to continue..." -ForegroundColor Yellow
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
    
} while ($true)
