@echo off
title Telmi V30 — Activer AUDIO PROBE
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Enable-Audio-Probe.ps1"
echo.
pause
