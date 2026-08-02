@echo off
title TelmiOS — Flash carte SD
cd /d "%~dp0"

echo.
echo  TelmiOS R36S — creation / flash carte SD
echo  -----------------------------------------
echo  [1] Image LATEST  (recommande : toutes nouveautes)
echo  [2] Expand TELMI  (apres Rufus)
echo  [3] Complet       (rootfs.tar + sync LATEST)
echo.

:: Elevation admin si besoin
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Demande des droits administrateur...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0flash-telmi-sd.ps1"
echo.
pause
