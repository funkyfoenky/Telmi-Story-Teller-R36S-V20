@echo off
:: Injecte le wrapper storyTeller dans la partition root de la SD (une fois)
:: Necessite admin. Adapte le numero de disque si besoin.
title Telmi V30 — Inject audio-probe wrapper
cd /d "%~dp0\.."

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Demande admin...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Inject-Audio-Probe-Wrapper.ps1"
echo.
pause
