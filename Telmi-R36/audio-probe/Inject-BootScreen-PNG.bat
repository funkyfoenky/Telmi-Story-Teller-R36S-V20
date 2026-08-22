@echo off
title Telmi V30 - Inject bootScreen PNG
cd /d "%~dp0"

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Demande admin...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Inject-BootScreen-PNG.ps1"
echo.
pause
