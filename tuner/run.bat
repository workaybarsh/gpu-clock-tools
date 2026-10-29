@echo off
setlocal
rem ============================================================
rem  SETTINGS - edit these lines only
rem ============================================================
set "MODE=Auto"
set "GPU_INDEX=0"
set "TARGET_TEMP=65"
set "PROCESS_NAME="
rem ------------------------------------------------------------
rem  MODE         : Detect | Status | Auto | Fixed | Percent | Clear
rem  GPU_INDEX    : 0 = first card, 1 = second card
rem  TARGET_TEMP  : temperature target in Celsius (Auto mode)
rem  PROCESS_NAME : process to watch, without .exe
rem                 multiple:  miner1,miner2
rem                 leave empty to run until Ctrl+C
rem
rem  NOTE: Auto mode requires the GPU to be under load.
rem        Start your miner first, then run this file.
rem ============================================================

rem --- self-elevate if not running as administrator ---
net session >nul 2>&1
if errorlevel 1 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

set "ARGS=-Mode %MODE% -GpuIndex %GPU_INDEX%"
if not "%TARGET_TEMP%"=="" set "ARGS=%ARGS% -TargetTemp %TARGET_TEMP%"
if not "%PROCESS_NAME%"=="" set "ARGS=%ARGS% -ProcessName %PROCESS_NAME%"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gpu-tune.ps1" %ARGS%
echo.
pause
