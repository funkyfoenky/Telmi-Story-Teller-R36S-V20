@echo off
:: Raccourci a la racine Telmi-R36 — Flash carte SD TelmiOS
:: Modes (via scripts\flash-telmi-sd.ps1) :
::   [1] Image LATEST  — dd output\telmi-r36-v20-*.img + expand TELMI (recommande)
::   [2] Expand        — apres Rufus : agrandit seulement TELMI
::   [3] Complet       — rootfs.tar + sync bins depuis LATEST
:: Inclut : GBA, PSX (CHD), volume libretro, luminosite, Games/*
cd /d "%~dp0scripts"
call "%~dp0scripts\Flash-Telmi-SD.bat"
