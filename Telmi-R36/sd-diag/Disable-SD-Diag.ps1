# Supprime le flag TELMI-SD-DIAG sur BOOT.
$ErrorActionPreference = 'Stop'

Write-Host ''
Write-Host ' Telmi V30 - Desactiver SD DIAG'
Write-Host ' ==============================='
$letter = (Read-Host 'Lettre du volume BOOT (ex: D)').Trim().TrimEnd(':')
if ($letter -notmatch '^[A-Za-z]$') { throw 'Lettre invalide' }
$bootRoot = "${letter}:"
$flag = Join-Path $bootRoot 'TELMI-SD-DIAG'
if (Test-Path $flag) {
    Remove-Item -Force $flag
    Write-Host " Supprime -> $flag"
} else {
    Write-Host " Deja absent : $flag"
}
Write-Host ' Boot Telmi normal au prochain demarrage.'
Write-Host ''
