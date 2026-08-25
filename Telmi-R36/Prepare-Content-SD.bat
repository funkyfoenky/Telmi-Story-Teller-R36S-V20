@echo off
:: Prepare SD CONTENU Telmi (slot gauche) - FAT32 label TELMI pour Telmi Sync
title TelmiOS - Prepare carte contenu (slot gauche)
cd /d "%~dp0"

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Demande des droits administrateur...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\prepare-content-sd.ps1" %*
echo.
pause
