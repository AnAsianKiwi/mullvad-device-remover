@echo off
title Manage Mullvad Devices
setlocal enabledelayedexpansion
mode con: cols=70 lines=15

set "DEVICE_COUNT=0"
set "MAX_DEVICES=1"
set "REVOKED_COUNT=0"

:: Initialize array for authorized devices
set "AUTHORIZED_DEVICES_COUNT=1"

:: Fetch current account key and store it as authorized key
for /f "tokens=2 delims=: " %%A in ('mullvad account get ^| findstr /c:"Mullvad account: "') do (
    set "AUTHORIZED_KEY=%%A"
)

:: Exit if we couldn't get the key
if not defined AUTHORIZED_KEY (
    echo Error: Could not fetch Mullvad account key.
    echo Please ensure Mullvad is installed and you are logged in.
    timeout /t 5
    exit /b
)

set /a "CHECK_INTERVAL=7200"
set "LAST_CHECK=%time%"
set "LAST_ACCOUNT_STATUS=Authorized"

:: Fetch the primary authorized device name and trim only leading/trailing spaces
for /f "tokens=2* delims=: " %%A in ('mullvad account get ^| findstr /c:"Device name:"') do (
    set "AUTHORIZED_DEVICE_1=%%B"
)

:PROMPT_EXTRA_DEVICE
cls
echo Current authorized device: !AUTHORIZED_DEVICE_1!
echo ----------------------------------------------------------------------
echo Would you like to add an extra authorized device? (Y/N)
choice /c YN /n
if errorlevel 2 goto LOOP
if errorlevel 1 (
    echo Enter the name of the device to authorize:
    set /p "AUTHORIZED_DEVICE_2="
    set /a "AUTHORIZED_DEVICES_COUNT=2"
    echo Added !AUTHORIZED_DEVICE_2! to authorized devices.
    timeout /t 2 /nobreak >nul
)

:LOOP
set "UNAUTHORIZED_COUNT=0"
set /a "DEVICE_COUNT=0"
set "NEEDS_UPDATE=0"

:: Clear previous unauthorized devices
for /L %%i in (1,1,10) do set "UNAUTHORIZED_DEVICE_%%i="

:: Check devices
for /f "skip=1 tokens=* usebackq" %%A in (`mullvad account list-devices`) do (
    set "DEVICE=%%A"
    
    if not "!DEVICE!"=="" (
        set /a "DEVICE_COUNT+=1"
        
        set "IS_AUTHORIZED=0"
        :: Check against all authorized devices
        for /L %%i in (1,1,!AUTHORIZED_DEVICES_COUNT!) do (
            if /i "!DEVICE!"=="!AUTHORIZED_DEVICE_%%i!" (
                set "IS_AUTHORIZED=1"
            )
        )
        
        if !IS_AUTHORIZED! equ 0 (
            set /a "UNAUTHORIZED_COUNT+=1"
            set "UNAUTHORIZED_DEVICE_!UNAUTHORIZED_COUNT!=!DEVICE!"
            set "NEEDS_UPDATE=1"
        )
    )
)

:: Generate random index for next device to revoke
if !UNAUTHORIZED_COUNT! gtr 0 (
    set /a "NEXT_TO_REVOKE=(!RANDOM! %% !UNAUTHORIZED_COUNT!) + 1"
)

if !DEVICE_COUNT! gtr %MAX_DEVICES% (
    if !UNAUTHORIZED_COUNT! gtr 0 (
        cls
        echo Authorized devices:
        for /L %%i in (1,1,!AUTHORIZED_DEVICES_COUNT!) do (
            echo   !AUTHORIZED_DEVICE_%%i!
        )
        echo ----------------------------------------------------------------------
        echo [ALERT] More than %MAX_DEVICES% devices connected.
        echo Revoking device: [!UNAUTHORIZED_DEVICE_%NEXT_TO_REVOKE%!]
        
        :: Revoke the device
        mullvad account revoke-device "!UNAUTHORIZED_DEVICE_%NEXT_TO_REVOKE%!"
        
        :: Update revoked count
        set /a "REVOKED_COUNT+=1"
        
        :: Show the number of devices removed
        echo Device revoked successfully.
        echo Total devices removed: !REVOKED_COUNT!
        timeout /t 3 /nobreak >nul
    )
)

:: Calculate time difference for periodic check
for /f "tokens=1-4 delims=:." %%a in ("%time%") do (
    set /a "SECONDS_NOW=(1%%a %% 100)*3600 + (1%%b %% 100)*60 + (1%%c %% 100)"
)
for /f "tokens=1-4 delims=:." %%a in ("%LAST_CHECK%") do (
    set /a "SECONDS_LAST=(1%%a %% 100)*3600 + (1%%b %% 100)*60 + (1%%c %% 100)"
)
set /a "SECONDS_DIFF=SECONDS_NOW-SECONDS_LAST"
if !SECONDS_DIFF! lss 0 set /a "SECONDS_DIFF+=86400"

if !SECONDS_DIFF! geq %CHECK_INTERVAL% (
    cls
    echo Authorized devices:
    for /L %%i in (1,1,!AUTHORIZED_DEVICES_COUNT!) do (
        echo   !AUTHORIZED_DEVICE_%%i!
    )
    echo ----------------------------------------------------------------------
    echo Performing periodic account check...

    set "ACCOUNT_KEY="
    for /f "tokens=2 delims=: " %%A in ('mullvad account get ^| findstr /c:"Mullvad account: "') do (
        set "ACCOUNT_KEY=%%A"
    )

    if "!ACCOUNT_KEY!"=="%AUTHORIZED_KEY%" (
        echo Account key verified.
        set "LAST_ACCOUNT_STATUS=Authorized"
    ) else (
        echo [ALERT] Unauthorized account key detected.
        set "LAST_ACCOUNT_STATUS=Unauthorized"
        echo Relogging to authorized account...
        mullvad account login %AUTHORIZED_KEY%
        timeout /t 1 /nobreak >nul
        mullvad connect
    )

    set "LAST_CHECK=%time%"
    timeout /t 3 /nobreak >nul
)

cls
echo Authorized devices:
for /L %%i in (1,1,!AUTHORIZED_DEVICES_COUNT!) do (
    echo   !AUTHORIZED_DEVICE_%%i!
)
echo ----------------------------------------------------------------------
echo Unauthorized devices (!UNAUTHORIZED_COUNT! found):
if !UNAUTHORIZED_COUNT! gtr 0 (
    for /L %%i in (1,1,!UNAUTHORIZED_COUNT!) do (
        echo   [!UNAUTHORIZED_DEVICE_%%i!]
    )
    echo ----------------------------------------------------------------------
    echo Next to be revoked: [!UNAUTHORIZED_DEVICE_%NEXT_TO_REVOKE%!]
) else (
    echo   None detected
    echo Next to be revoked: None
)

:: Display total number of devices removed
echo ----------------------------------------------------------------------
echo Total devices removed: !REVOKED_COUNT!

timeout /t 1 /nobreak >nul

goto LOOP