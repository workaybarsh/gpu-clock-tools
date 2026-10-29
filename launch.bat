@echo off
setlocal
title GPU Clock Tools
set "BASE=%~dp0"
set "TUNE=%BASE%tuner\gpu-tune.ps1"
set "WD=%BASE%watchdog\gpu-clock-watchdog.ps1"
set "PS=powershell -NoProfile -ExecutionPolicy Bypass -File"

rem --- elevate if needed (clock changes require administrator) ---
net session >nul 2>&1
if errorlevel 1 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

:menu
cls
echo.
echo   ==========================================================
echo      GPU CLOCK TOOLS
echo   ==========================================================
echo.
echo      1^)  Detect card            (read only, nothing changes)
echo      2^)  Auto tune + watch      (find safe clock, then hold it)
echo      3^)  Watchdog only          (use the saved profile)
echo      4^)  Watchdog, fixed clock  (enter MHz yourself)
echo      5^)  Clear lock             (back to driver defaults)
echo      6^)  Status
echo      0^)  Exit
echo.
set "c="
set /p "c=   Choice: "
if not defined c goto menu
if "%c%"=="1" goto detect
if "%c%"=="2" goto auto
if "%c%"=="3" goto watch
if "%c%"=="4" goto fixed
if "%c%"=="5" goto clear
if "%c%"=="6" goto status
if "%c%"=="0" exit /b 0
goto menu

:detect
%PS% "%TUNE%" -Mode Detect
goto done

:auto
set "t=65"
set /p "t=   Temperature target in C [65]: "
%PS% "%TUNE%" -Mode Auto -TargetTemp %t%
goto done

:watch
%PS% "%WD%"
goto done

:fixed
set "mhz="
set /p "mhz=   Clock ceiling in MHz (e.g. 1900): "
if not defined mhz goto menu
%PS% "%WD%" -TargetClock %mhz%
goto done

:clear
%PS% "%TUNE%" -Mode Clear
goto done

:status
%PS% "%TUNE%" -Mode Status
goto done

:done
echo.
pause
goto menu
