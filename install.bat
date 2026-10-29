@echo off
setlocal
title GPU Clock Tools - Install
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
pause
