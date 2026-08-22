@echo off
title Telmi V30 — Desactiver AUDIO PROBE
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Disable-Audio-Probe.ps1"
echo.
pause
