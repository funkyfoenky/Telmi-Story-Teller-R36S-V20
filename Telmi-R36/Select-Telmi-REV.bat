@echo off
title TelmiOS - Select REV (V20 / V30 / ...)
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Select-Telmi-REV.ps1"
echo.
pause
