# --- 1. DISABLE QUICKEDIT ---
$code = @'
[DllImport("kernel32.dll")]
public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
[DllImport("kernel32.dll")]
public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll")]
public static extern IntPtr GetStdHandle(int nStdHandle);
'@
$type = Add-Type -MemberDefinition $code -Name "Win32" -Namespace Win32 -PassThru
$handle = $type::GetStdHandle(-10) 
$mode = 0
$type::GetConsoleMode($handle, [ref]$mode)
$mode = $mode -band -bnot 0x0040 
$type::SetConsoleMode($handle, $mode)

# --- 2. SETUP WINDOW ---
$Host.UI.RawUI.WindowTitle = "Mullvad Auto-Relogin"
try {
    $Host.UI.RawUI.WindowSize = New-Object System.Management.Automation.Host.Size(70, 25)
    $Host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size(70, 25)
} catch {}

# Configuration
$MaxDevices = 1
$AuthorizedDevice1 = "Unknown"
$AuthorizedFriends = [System.Collections.ArrayList]@()

# --- HELPER FUNCTIONS ---

function Get-CurrentDeviceName {
    $output = mullvad account get 2>&1
    foreach ($line in $output) {
        if ($line -match "Device name:\s*(.+)") {
            return $matches[1].Trim()
        }
    }
    return "Unknown"
}

# Initial Fetch
$AuthorizedDevice1 = Get-CurrentDeviceName

# --- MENUS ---

function Show-Menu {
    $inputBuffer = ""
    while ($true) {
        $script:AuthorizedDevice1 = Get-CurrentDeviceName

        Clear-Host
        Write-Host "`n ======================================================================" -ForegroundColor Cyan
        Write-Host "  MULLVAD DEVICE REMOVER" -ForegroundColor White
        Write-Host " ======================================================================" -ForegroundColor Cyan
        Write-Host "  Device : $AuthorizedDevice1" -ForegroundColor Gray
        Write-Host " ======================================================================" -ForegroundColor Cyan
        Write-Host "`n  [1] Monitor"
        Write-Host "  [2] Authorize Devices"
        Write-Host "  [3] Exit`n"
        Write-Host " ======================================================================" -ForegroundColor Cyan
        Write-Host " >> Select Option: $inputBuffer" -NoNewline

        $loops = 0
        while ($loops -lt 10) { 
            if ([Console]::KeyAvailable) {
                $keyInfo = [Console]::ReadKey($true)
                if ($keyInfo.Key -eq "Enter") {
                    $finalInput = $inputBuffer
                    $inputBuffer = "" 
                    switch ($finalInput) {
                        "1" { Start-Monitor; return }
                        "2" { Select-Friend; return }
                        "3" { exit }
                    }
                    break 
                }
                elseif ($keyInfo.Key -eq "Backspace") {
                    if ($inputBuffer.Length -gt 0) {
                        $inputBuffer = $inputBuffer.Substring(0, $inputBuffer.Length - 1)
                        Write-Host "`b `b" -NoNewline
                    }
                }
                else {
                    $char = $keyInfo.KeyChar
                    if ($char -match "[0-9]") {
                        $inputBuffer += $char
                        Write-Host $char -NoNewline
                    }
                }
            }
            Start-Sleep -Milliseconds 100
            $loops++
        }
    }
}

function Select-Friend {
    $inputBuffer = ""
    while ($true) {
        # Check login status immediately
        $accStatus = @(mullvad account get 2>&1) | Out-String
        if ($accStatus -match "revoked" -or $accStatus -match "Not logged in") {
            Write-Host "`n [!] You are revoked/logged out. Return to Monitor [1] to fix." -ForegroundColor Red
            Start-Sleep -Seconds 2
            return
        }

        $rawDevices = @(mullvad account list-devices 2>&1)
        $AllActiveDevices = @()
        $AllCandidates = @()
        
        foreach ($line in $rawDevices) {
            $t = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($t) -or $t -match "Devices on the account") { continue }
            $cleanName = $t.Replace(" (This device)", "").Trim()
            $AllActiveDevices += $cleanName
            if ($cleanName -ne $AuthorizedDevice1) {
                $isCurrentlyAuth = $script:AuthorizedFriends.Contains($cleanName)
                $AllCandidates += [PSCustomObject]@{ Name = $cleanName; IsAuthorized = $isCurrentlyAuth }
            }
        }

        # Cleanup
        $friendsToRemove = @()
        foreach ($friend in $script:AuthorizedFriends) {
            if ($AllActiveDevices -notcontains $friend) { $friendsToRemove += $friend }
        }
        foreach ($friend in $friendsToRemove) { $null = $script:AuthorizedFriends.Remove($friend) }

        Clear-Host
        Write-Host "`n ======================================================================" -ForegroundColor Cyan
        Write-Host "  AUTHORIZE / DE-AUTHORIZE DEVICES" -ForegroundColor White
        Write-Host " ======================================================================" -ForegroundColor Cyan
        Write-Host "  [0] Back" -ForegroundColor Gray
        
        $idx = 0
        if ($AllCandidates.Count -gt 0) {
            foreach ($candidate in $AllCandidates) {
                $idx++
                $candidate | Add-Member -NotePropertyName Index -NotePropertyValue $idx
                $color = if ($candidate.IsAuthorized) { "Green" } else { "White" }
                Write-Host "  [$idx] $($candidate.Name)" -ForegroundColor $color
            }
        } else { Write-Host "  [] No other devices found." -ForegroundColor DarkGray }

        Write-Host "`n >> Enter number to toggle: $inputBuffer" -NoNewline

        $loops = 0
        while ($loops -lt 20) { 
            if ([Console]::KeyAvailable) {
                $keyInfo = [Console]::ReadKey($true)
                if ($keyInfo.Key -eq "Enter") {
                    if ($inputBuffer -eq "0") { Show-Menu; return }
                    $match = $AllCandidates | Where-Object { $_.Index -eq $inputBuffer }
                    if ($match) {
                        if ($match.IsAuthorized) { $script:AuthorizedFriends.Remove($match.Name) } 
                        else { $script:AuthorizedFriends.Add($match.Name) }
                        $inputBuffer = ""; break 
                    } else { $inputBuffer = ""; break }
                }
                elseif ($keyInfo.Key -eq "Backspace") {
                    if ($inputBuffer.Length -gt 0) { $inputBuffer = $inputBuffer.Substring(0, $inputBuffer.Length - 1); Write-Host "`b `b" -NoNewline }
                }
                else {
                    $char = $keyInfo.KeyChar
                    if ($char -match "[0-9]") { $inputBuffer += $char; Write-Host $char -NoNewline }
                }
            }
            Start-Sleep -Milliseconds 100
            $loops++
        }
    }
}

function Start-Monitor {
    $RevokedCount = 0
    $inputBuffer = ""
    
    while ($true) {
        
        # --- 1. CHECK ACCOUNT STATUS (mullvad account get) ---
        # This is the "Source of Truth" for revocation
        $checkAccount = @(mullvad account get 2>&1) | Out-String

        if ($checkAccount -match "revoked" -or $checkAccount -match "Not logged in") {
            Clear-Host
            Write-Host "`n [!] DETECTED REVOCATION." -ForegroundColor Yellow
            
            # Extract number
            if ($checkAccount -match "Mullvad account:\s*([\d\s]+)") {
                $recoveredAcc = $matches[1].Replace(" ", "").Trim()
                
                Write-Host " [~] Auto-Login ($recoveredAcc)..." -ForegroundColor Cyan
                
                # Execute Login (No logout needed per your testing)
                mullvad account login $recoveredAcc | Out-Null
                
                # Refresh Device Name
                $script:AuthorizedDevice1 = Get-CurrentDeviceName
                
                Write-Host " [OK] Logged in. Resuming monitor..." -ForegroundColor Green
                Start-Sleep -Seconds 2
                continue # Restart Loop
            } else {
                 Write-Host " [X] Error: Could not find account number in output." -ForegroundColor Red
                 Write-Host $checkAccount
                 Start-Sleep -Seconds 5
                 return
            }
        }

        # --- 2. CHECK DEVICES (mullvad account list-devices) ---
        $checkDevices = @(mullvad account list-devices 2>&1)
        
        $UnauthorizedList = @()
        $AllActiveDevices = @()
        $DeviceCount = 0
        
        foreach ($line in $checkDevices) {
            $t = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($t) -or $t -match "Devices on the account") { continue }

            $DeviceCount++
            $cleanName = $t.Replace(" (This device)", "").Trim()
            $AllActiveDevices += $cleanName

            $isAuth = $false
            if ($cleanName -eq $AuthorizedDevice1) { $isAuth = $true }
            if ($script:AuthorizedFriends.Contains($cleanName)) { $isAuth = $true }

            if (-not $isAuth) {
                $UnauthorizedList += $cleanName
            }
        }
        
        # Sync Friends List
        $friendsToRemove = @()
        foreach ($friend in $script:AuthorizedFriends) {
            if ($AllActiveDevices -notcontains $friend) { $friendsToRemove += $friend }
        }
        foreach ($friend in $friendsToRemove) { $null = $script:AuthorizedFriends.Remove($friend) }
        
        $script:MaxDevices = 1 + $script:AuthorizedFriends.Count

        $NextToRevoke = "None"
        if ($UnauthorizedList.Count -gt 0) {
            $NextToRevoke = $UnauthorizedList | Get-Random
        }

        # --- 3. DASHBOARD ---
        Clear-Host
        Write-Host " Authorized devices:" -ForegroundColor White
        Write-Host "   [$AuthorizedDevice1]" -ForegroundColor Green
        foreach ($friend in $script:AuthorizedFriends) { Write-Host "   [$friend]" -ForegroundColor Green }
        
        Write-Host " ----------------------------------------------------------------------" -ForegroundColor DarkGray
        Write-Host " Unauthorized devices ($($UnauthorizedList.Count) found):" -ForegroundColor White
        
        if ($UnauthorizedList.Count -gt 0) {
            foreach ($badDevice in $UnauthorizedList) { Write-Host "   [$badDevice]" -ForegroundColor Red }
        } else { Write-Host "   None detected" -ForegroundColor Gray }

        Write-Host " ----------------------------------------------------------------------" -ForegroundColor DarkGray
        Write-Host " Total devices removed: $RevokedCount"
        
        # --- 4. ACTION ---
        if ($DeviceCount -gt $MaxDevices -and $UnauthorizedList.Count -gt 0) {
            Write-Host "`n [ALERT] Revoking $NextToRevoke..." -ForegroundColor Red
            mullvad account revoke-device "$NextToRevoke" | Out-Null
            $RevokedCount++
            Start-Sleep -Seconds 2
        }

        Write-Host "`n >> Enter 0 to menu: $inputBuffer" -NoNewline

        # --- 5. INPUT ---
        $loops = 0
        while ($loops -lt 10) { 
            if ([Console]::KeyAvailable) {
                $keyInfo = [Console]::ReadKey($true)
                if ($keyInfo.Key -eq "Enter") {
                    if ($inputBuffer -eq "0") { Show-Menu; return }
                    $inputBuffer = ""; break 
                }
                elseif ($keyInfo.Key -eq "Backspace") {
                    if ($inputBuffer.Length -gt 0) { $inputBuffer = $inputBuffer.Substring(0, $inputBuffer.Length - 1); Write-Host "`b `b" -NoNewline }
                }
                else {
                    $char = $keyInfo.KeyChar
                    if ($char -match "[0-9]") { $inputBuffer += $char; Write-Host $char -NoNewline }
                }
            }
            Start-Sleep -Milliseconds 100
            $loops++
        }
    }
}

Show-Menu