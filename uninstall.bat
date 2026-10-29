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

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
pause