@echo off
:: Flash TelmiOS image unique multi-REV — Windows natif (pas de WSL)
:: Apres flash : lancez Select-Telmi-REV.bat pour choisir la revision.
title TelmiOS - Flash SD (Windows natif)
cd /d "%~dp0"

echo.
echo  TelmiOS R36S - flash + expand TELMI (Windows)
echo  ---------------------------------------------
echo  1) Flash LATEST.img puis agrandit la partition TELMI
echo  2) Puis Select-Telmi-REV.bat (V20 ou V30 Panel4)
echo  (Aucun WSL / usbipd requis)
echo.

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Demande des droits administrateur...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\flash-telmi-sd-win.ps1" %*
echo.
echo  Si le flash a reussi : lancez Select-Telmi-REV.bat
echo.
pause
