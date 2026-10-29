@echo off
setlocal
rem ============================================================
rem  SETTINGS - edit these lines only
rem ============================================================
set "GPU_INDEX=0"
set "TARGET_CLOCK="
set "PERCENT="
set "PROCESS_NAME="
set "LOAD_THRESHOLD=20"
rem ------------------------------------------------------------
rem  GPU_INDEX      : 0 = first card, 1 = second card
rem
rem  TARGET_CLOCK   : clock ceiling in MHz (e.g. 1900)
rem                   leave empty to read gpu-profile.json instead
rem
rem  PERCENT        : percentage of the max clock (e.g. 76)
rem                   only used when TARGET_CLOCK is empty
rem
rem  PROCESS_NAME   : process to watch, without .exe
rem                   leave EMPTY to auto-detect whatever uses the GPU
rem                   multiple: miner1,miner2
rem
rem  LOAD_THRESHOLD : GPU utilization (%) that counts as "busy"
rem ============================================================

rem --- self-elevate if not running as administrator ---
net session >nul 2>&1
if errorlevel 1 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

set "ARGS=-GpuIndex %GPU_INDEX% -LoadThreshold %LOAD_THRESHOLD%"
if not "%TARGET_CLOCK%"=="" set "ARGS=%ARGS% -TargetClock %TARGET_CLOCK%"
if not "%PERCENT%"=="" set "ARGS=%ARGS% -Percent %PERCENT%"
if not "%PROCESS_NAME%"=="" set "ARGS=%ARGS% -ProcessName %PROCESS_NAME%"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gpu-clock-watchdog.ps1" %ARGS%
echo.
pause
