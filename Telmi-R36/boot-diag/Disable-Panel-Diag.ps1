#Requires -Version 5
$ErrorActionPreference = 'Stop'
$letter = (Read-Host 'Lettre BOOT').Trim().TrimEnd(':')
$flag = "${letter}:\TELMI-PANEL-DIAG"
if (Test-Path $flag) { Remove-Item -Force $flag; Write-Host "OK supprime $flag" }
else { Write-Host "Absent : $flag" }
