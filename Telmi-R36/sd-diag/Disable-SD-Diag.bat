@echo off
title Telmi V30 — Desactiver SD DIAG
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Disable-SD-Diag.ps1"
echo.
pause
