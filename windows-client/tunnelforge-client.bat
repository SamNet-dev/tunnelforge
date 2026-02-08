@echo off
setlocal EnableDelayedExpansion
title TunnelForge Client
color 0A

:: TunnelForge Client for Windows
:: Download this file and run it. Paste your connection
:: code and you're connected.

set "CONF_DIR=%USERPROFILE%\.tunnelforge-client"
set "STUNNEL_CONF=%CONF_DIR%\stunnel.conf"
set "PSK_FILE=%CONF_DIR%\psk.txt"
set "PID_FILE=%CONF_DIR%\stunnel.pid"
set "LOG_FILE=%CONF_DIR%\stunnel.log"
set "SAVED_FILE=%CONF_DIR%\connection.dat"

if /i "%~1"=="stop" goto :do_stop
if /i "%~1"=="status" goto :do_status

echo.
echo   ===================================
echo      TunnelForge Client v1.0
echo      Secure TLS+PSK Connection
echo   ===================================
echo.

if not exist "%CONF_DIR%" mkdir "%CONF_DIR%" 2>nul

if exist "%SAVED_FILE%" (
    echo   [*] Found saved connection.
    set /p "REUSE=  Use saved connection? [Y/n]: "
    if /i "!REUSE!"=="n" goto :new_connection
    for /f "tokens=1,2,3,4 delims=:" %%a in ('type "%SAVED_FILE%"') do (
        set "SERVER=%%a"
        set "PORT=%%b"
        set "LOCAL_PORT=%%c"
        set "PSK=%%d"
    )
    if defined SERVER if defined PSK goto :connect
    echo   [X] Saved connection is invalid. Enter new details.
)

:new_connection
echo.
echo   Enter connection details from your admin:
echo   (Ask them to run: tunnelforge client-config ^<profile^>)
echo.
set /p "SERVER=  Server address: "
if "!SERVER!"=="" (
    echo   [X] Server address required.
    goto :new_connection
)
set /p "PORT=  Port [1443]: "
if "!PORT!"=="" set "PORT=1443"
set /p "LOCAL_PORT=  Local SOCKS5 port [1080]: "
if "!LOCAL_PORT!"=="" set "LOCAL_PORT=1080"
set /p "PSK=  PSK secret key: "
if "!PSK!"=="" (
    echo   [X] PSK key required.
    goto :new_connection
)

echo !SERVER!:!PORT!:!LOCAL_PORT!:!PSK!> "%SAVED_FILE%"
attrib +h "%SAVED_FILE%" 2>nul

:connect
echo.
echo   [*] Server:  !SERVER!:!PORT!
echo   [*] Proxy:   127.0.0.1:!LOCAL_PORT!
echo.

set "STUNNEL_BIN="

for %%p in (
    "C:\Program Files (x86)\stunnel\bin\stunnel.exe"
    "C:\Program Files\stunnel\bin\stunnel.exe"
    "%ProgramFiles%\stunnel\bin\stunnel.exe"
    "%ProgramFiles(x86)%\stunnel\bin\stunnel.exe"
    "%CONF_DIR%\stunnel\bin\stunnel.exe"
) do (
    if exist %%p set "STUNNEL_BIN=%%~p"
)

if "!STUNNEL_BIN!"=="" (
    where stunnel >nul 2>&1
    if !errorlevel!==0 (
        for /f "delims=" %%i in ('where stunnel 2^>nul') do set "STUNNEL_BIN=%%i"
    )
)

if "!STUNNEL_BIN!"=="" (
    echo   [X] stunnel not found. Installing...
    echo.
    where winget >nul 2>&1
    if !errorlevel!==0 (
        echo   [*] Trying winget...
        winget install --id stunnel.stunnel --accept-source-agreements --accept-package-agreements >nul 2>&1
        for %%p in (
            "C:\Program Files (x86)\stunnel\bin\stunnel.exe"
            "C:\Program Files\stunnel\bin\stunnel.exe"
        ) do (
            if exist %%p set "STUNNEL_BIN=%%~p"
        )
    )
    if "!STUNNEL_BIN!"=="" (
        where choco >nul 2>&1
        if !errorlevel!==0 (
            echo   [*] Trying chocolatey...
            choco install stunnel -y >nul 2>&1
            for %%p in (
                "C:\Program Files (x86)\stunnel\bin\stunnel.exe"
                "C:\Program Files\stunnel\bin\stunnel.exe"
            ) do (
                if exist %%p set "STUNNEL_BIN=%%~p"
            )
        )
    )
    if "!STUNNEL_BIN!"=="" (
        echo.
        echo   [X] Could not install stunnel automatically.
        echo.
        echo   Please install manually:
        echo     1. Go to https://www.stunnel.org/downloads.html
        echo     2. Download "stunnel-X.XX-win64-installer.exe"
        echo     3. Install with default settings
        echo     4. Run this script again
        echo.
        pause
        exit /b 1
    )
)

echo   [+] stunnel found: !STUNNEL_BIN!

:: Check if already connected (port listening)
netstat -an 2>nul | find ":!LOCAL_PORT! " | find "LISTENING" >nul 2>&1
if !errorlevel!==0 (
    echo   [+] Already connected
    echo       SOCKS5 proxy: 127.0.0.1:!LOCAL_PORT!
    echo.
    echo   Browser Setup:
    echo     Firefox: Settings - Proxy - Manual
    echo       SOCKS Host: 127.0.0.1
    echo       Port: !LOCAL_PORT!
    echo       Select SOCKS v5
    echo       Check "Proxy DNS when using SOCKS v5"
    echo.
    echo     Chrome:
    echo       chrome --proxy-server="socks5://127.0.0.1:!LOCAL_PORT!"
    echo.
    echo   Run "%~nx0 stop" to disconnect
    goto :done
)

echo tunnelforge:!PSK!> "%PSK_FILE%"

(
echo ; TunnelForge client config
echo output = %LOG_FILE%
echo.
echo [tunnelforge]
echo client = yes
echo accept = 127.0.0.1:!LOCAL_PORT!
echo connect = !SERVER!:!PORT!
echo PSKsecrets = %PSK_FILE%
echo ciphers = PSK
) > "%STUNNEL_CONF%"

echo   [*] Connecting to !SERVER!:!PORT!...
start "" "!STUNNEL_BIN!" "%STUNNEL_CONF%"

timeout /t 4 /nobreak >nul 2>&1

:: Check if local port is now listening
netstat -an 2>nul | find ":!LOCAL_PORT! " | find "LISTENING" >nul 2>&1
if !errorlevel!==0 (
    echo.
    echo   ===================================
    echo          Connected
    echo   ===================================
    echo.
    echo   SOCKS5 Proxy:  127.0.0.1:!LOCAL_PORT!
    echo.
    echo   Browser Setup:
    echo     Firefox: Settings - Proxy - Manual
    echo       SOCKS Host: 127.0.0.1
    echo       Port: !LOCAL_PORT!
    echo       Select SOCKS v5
    echo       Check "Proxy DNS when using SOCKS v5"
    echo.
    echo     Chrome:
    echo       chrome --proxy-server="socks5://127.0.0.1:!LOCAL_PORT!"
    echo.
    echo   Commands:
    echo     %~nx0 status  - check connection
    echo     %~nx0 stop    - disconnect
    echo.
    goto :done
)

echo   [X] Connection failed.
echo       Check %LOG_FILE% for details.
echo.
if exist "%LOG_FILE%" (
    echo   Last log entries:
    for /f "tokens=*" %%l in ('type "%LOG_FILE%" 2^>nul') do echo     %%l
)
goto :done

:do_stop
tasklist /fi "IMAGENAME eq stunnel.exe" 2>nul | find "stunnel" >nul 2>&1
if !errorlevel!==1 (
    echo   [X] Not connected.
    goto :done
)
taskkill /im stunnel.exe /f >nul 2>&1
echo   [+] Disconnected.
goto :done

:do_status
netstat -an 2>nul | find ":!LOCAL_PORT! " | find "LISTENING" >nul 2>&1
if !errorlevel!==0 (
    echo   [+] Connected
    echo       SOCKS5 proxy: 127.0.0.1:!LOCAL_PORT!
) else (
    echo   [X] Not connected
)
goto :done

:done
echo.
pause
endlocal
