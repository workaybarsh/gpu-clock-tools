@echo off
setlocal
title GPU Clock Tools - Uninstall

rem --- elevate: needed to release the clock lock and to stop elevated processes ---
net session >nul 2>&1
if errorlevel 1 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo.
echo   This removes the app, the Start menu shortcut, the saved profile
echo   and releases any active clock lock.
echo.
set "ok="
set /p "ok=   Type Y to continue: "
if /i not "%ok%"=="Y" exit /b 0

rem --- run from %TEMP% so the script can delete its own install folder ---
set "TMPSCRIPT=%TEMP%\gpu-clock-uninstall.ps1"
copy /y "%~dp0uninstall.ps1" "%TMPSCRIPT%" >nul

powershell -NoProfile -ExecutionPolicy Bypass -File "%TMPSCRIPT%" %*

del /q "%TMPSCRIPT%" >nul 2>&1
pause
