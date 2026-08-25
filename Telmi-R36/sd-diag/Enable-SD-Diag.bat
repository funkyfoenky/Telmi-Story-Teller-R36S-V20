@echo off
title Telmi V30 — Activer SD DIAG
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Enable-SD-Diag.ps1"
echo.
pause
