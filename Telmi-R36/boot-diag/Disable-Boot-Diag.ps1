# Supprime le flag TELMI-BOOT-DIAG sur BOOT.
#Requires -Version 5
$ErrorActionPreference = 'Stop'
$letter = (Read-Host 'Lettre du volume BOOT (ex: D)').Trim().TrimEnd(':')
if ($letter -notmatch '^[A-Za-z]$') { throw 'Lettre invalide' }
$flag = "${letter}:\TELMI-BOOT-DIAG"
if (Test-Path $flag) {
    Remove-Item -Force $flag
    Write-Host " Flag supprime : $flag"
} else {
    Write-Host ' Flag deja absent.'
}
Write-Host ' Remettez un DTB panel (Select-Telmi-REV ou copie manuelle) pour un boot normal.'
