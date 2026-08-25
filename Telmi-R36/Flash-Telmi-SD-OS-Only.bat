@echo off
:: Flash OS Telmi sur slot DROIT sans partition contenu (dual-SD)
title TelmiOS - Flash OS only (slot droit)
cd /d "%~dp0"

net session >nul 2>&1
if %errorLevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\flash-telmi-sd-win.ps1" -Mode os-only %*
echo.
pause
