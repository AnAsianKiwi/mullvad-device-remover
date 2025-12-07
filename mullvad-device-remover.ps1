# --- 1. DISABLE QUICKEDIT (Prevents Freezing) ---
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
$Host.UI.RawUI.WindowTitle = "Mullvad Device Remover"
try {
    $Host.UI.RawUI.WindowSize = New-Object System.Management.Automation.Host.Size(70, 25)
    $Host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size(70, 25)
} catch {}

# Configuration
$MaxDevices = 1
$AuthorizedDevice1 = "Unknown"
# CHANGE: We now support multiple authorized friends
$AuthorizedFriends = [System.Collections.ArrayList]@()

# --- HELPER FUNCTIONS ---

function Get-CurrentDeviceName {
    $output = mullvad account get
    foreach ($line in $output) {
        if ($line -match "Device name:") {
            $parts = $line -split ":", 2
            if ($parts.Count -ge 2) {
                return $parts[1].Trim()
            }
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
        # FETCH DATA 
        $rawDevices = @(mullvad account list-devices)
        $AllActiveDevices = @()
        $AllCandidates = @()
        
        foreach ($line in $rawDevices) {
            $t = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($t) -or $t -match "Devices on the account") { continue }
            
            $cleanName = $t.Replace(" (This device)", "").Trim()
            $AllActiveDevices += $cleanName
            
            # Add to list if it is NOT my device
            if ($cleanName -ne $AuthorizedDevice1) {
                $isCurrentlyAuth = $script:AuthorizedFriends.Contains($cleanName)
                $AllCandidates += [PSCustomObject]@{ Name = $cleanName; IsAuthorized = $isCurrentlyAuth }
            }
        }

        # VALIDATION CHECK: Remove any authorized friends who have logged out
        $friendsToRemove = @()
        foreach ($friend in $script:AuthorizedFriends) {
            if ($AllActiveDevices -notcontains $friend) {
                $friendsToRemove += $friend
            }
        }
        foreach ($friend in $friendsToRemove) {
            $null = $script:AuthorizedFriends.Remove($friend)
        }

        # DRAW SCREEN
        Clear-Host
        Write-Host "`n ======================================================================" -ForegroundColor Cyan
        Write-Host "  AUTHORIZE / DE-AUTHORIZE DEVICES" -ForegroundColor White
        Write-Host " ======================================================================" -ForegroundColor Cyan
        Write-Host ""
        
        Write-Host "  [0] Menu / Cancel" -ForegroundColor Gray
        
        $idx = 0
        if ($AllCandidates.Count -gt 0) {
            foreach ($candidate in $AllCandidates) {
                $idx++
                $candidate | Add-Member -NotePropertyName Index -NotePropertyValue $idx
                
                $color = if ($candidate.IsAuthorized) { "Green" } else { "White" }
                Write-Host "  [$idx] $($candidate.Name)" -ForegroundColor $color
            }
        } else {
             Write-Host "  [] No other devices found." -ForegroundColor DarkGray
        }

        Write-Host "`n ======================================================================" -ForegroundColor Cyan
        Write-Host " >> Enter number to toggle authorization: $inputBuffer" -NoNewline

        # INPUT HANDLING
        $loops = 0
        while ($loops -lt 20) { 
            if ([Console]::KeyAvailable) {
                $keyInfo = [Console]::ReadKey($true)
                
                if ($keyInfo.Key -eq "Enter") {
                    $finalInput = $inputBuffer
                    if ($finalInput -eq "0") { Show-Menu; return }
                    
                    $match = $AllCandidates | Where-Object { $_.Index -eq $finalInput }
                    if ($match) {
                        # TOGGLE LOGIC
                        if ($match.IsAuthorized) {
                            # De-authorize
                            $null = $script:AuthorizedFriends.Remove($match.Name)
                            Write-Host "`n`n  [OK] De-authorized: $($match.Name)" -ForegroundColor Yellow
                        } else {
                            # Authorize
                            $null = $script:AuthorizedFriends.Add($match.Name)
                            Write-Host "`n`n  [OK] Authorized: $($match.Name)" -ForegroundColor Green
                        }
                        $inputBuffer = ""
                        Start-Sleep -Seconds 1
                        break 
                    } else {
                        $inputBuffer = "" 
                        break 
                    }
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

function Start-Monitor {
    $RevokedCount = 0
    $inputBuffer = ""
    
    while ($true) {
        # 1. PROCESSING
        $rawList = @(mullvad account list-devices)
        $UnauthorizedList = @()
        $AllActiveDevices = @()
        $DeviceCount = 0
        
        foreach ($line in $rawList) {
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
        
        # VALIDATION CHECK
        $friendsToRemove = @()
        foreach ($friend in $script:AuthorizedFriends) {
            if ($AllActiveDevices -notcontains $friend) {
                $friendsToRemove += $friend
            }
        }
        foreach ($friend in $friendsToRemove) {
            $null = $script:AuthorizedFriends.Remove($friend)
        }
        
        # Set device limit based on number of friends + self
        $script:MaxDevices = 1 + $script:AuthorizedFriends.Count

        $NextToRevoke = "None"
        if ($UnauthorizedList.Count -gt 0) {
            $NextToRevoke = $UnauthorizedList | Get-Random
        }

        # 2. DRAW DASHBOARD
        Clear-Host
        Write-Host " Authorized devices:" -ForegroundColor White
        
        Write-Host "   [$AuthorizedDevice1]" -ForegroundColor Green
        foreach ($friend in $script:AuthorizedFriends) {
            Write-Host "   [$friend]" -ForegroundColor Green
        }
        
        Write-Host " ----------------------------------------------------------------------" -ForegroundColor DarkGray
        Write-Host " Unauthorized devices ($($UnauthorizedList.Count) found):" -ForegroundColor White
        
        if ($UnauthorizedList.Count -gt 0) {
            foreach ($badDevice in $UnauthorizedList) {
                Write-Host "   [$badDevice]" -ForegroundColor Red
            }
        } else {
            Write-Host "   None detected" -ForegroundColor Gray
        }

        Write-Host " ----------------------------------------------------------------------" -ForegroundColor DarkGray
        Write-Host " Total devices removed: $RevokedCount"
        
        # 3. ACTION LOGIC
        if ($DeviceCount -gt $MaxDevices -and $UnauthorizedList.Count -gt 0) {
            Write-Host "`n [ALERT] Unauthorized device. Revoking $NextToRevoke..." -ForegroundColor Red
            
            mullvad account revoke-device "$NextToRevoke" | Out-Null
            
            $RevokedCount++
            Start-Sleep -Seconds 2
        }

        Write-Host "`n >> Enter 0 to menu / cancel: $inputBuffer" -NoNewline

        # 4. INPUT HANDLING
        $loops = 0
        while ($loops -lt 10) { 
            if ([Console]::KeyAvailable) {
                $keyInfo = [Console]::ReadKey($true)
                
                if ($keyInfo.Key -eq "Enter") {
                    $finalInput = $inputBuffer
                    if ($finalInput -eq "0") { Show-Menu; return }
                    $inputBuffer = ""
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

# Start
Show-Menu