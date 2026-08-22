@echo off
:: DEPRECATED : utilisez Flash-Telmi-SD.bat (image unique) puis Select-Telmi-REV.bat
title TelmiOS V30 - DEPRECATED -> image unique
cd /d "%~dp0"
echo.
echo  Flash-Telmi-SD-V30.bat est DEPRECATED.
echo  Flux recommande :
echo    1) Flash-Telmi-SD.bat   (image unique telmi-r36-*.img)
echo    2) Select-Telmi-REV.bat (choisir V30 Panel4)
echo.
echo  Relance le flash unique maintenant...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\flash-telmi-sd.ps1" -Profile v20
echo.
pause
