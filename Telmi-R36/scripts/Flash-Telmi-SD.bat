@echo off
:: Lanceur depuis scripts\ — delegue au Flash racine (Windows natif)
cd /d "%~dp0.."
call "%~dp0..\Flash-Telmi-SD.bat" %*
