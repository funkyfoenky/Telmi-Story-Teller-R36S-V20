@echo off
title Telmi V30 - Appliquer correctif audio Path=HP
cd /d "%~dp0"

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Demande admin...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Apply-V30-Audio-HP.ps1"
echo.
pause
