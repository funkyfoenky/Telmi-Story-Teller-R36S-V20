@echo off
:: Expand seulement la partition TELMI (apres Rufus / flash image sans expand)
title TelmiOS - Expand TELMI (Windows natif)
cd /d "%~dp0"

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Demande des droits administrateur...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\flash-telmi-sd-win.ps1" -Mode expand %*
echo.
pause
