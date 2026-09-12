# Cree le flag TELMI-BOOT-DIAG sur le volume BOOT (carte OS).
#Requires -Version 5
$ErrorActionPreference = 'Stop'

Write-Host ''
Write-Host ' Telmi - Activer BOOT DIAG (headless)'
Write-Host ' ====================================='
Write-Host ' Necessite image >= 0.6.7 (script telmi-boot-diag.sh).'
Write-Host ' DTB recommande : y3506-bootdiag.dtb -> rf3536k3ka.dtb'
Write-Host ''
$letter = (Read-Host 'Lettre du volume BOOT (ex: D)').Trim().TrimEnd(':')
if ($letter -notmatch '^[A-Za-z]$') { throw 'Lettre invalide' }
$bootRoot = "${letter}:"
if (-not (Test-Path $bootRoot)) { throw "Lecteur $bootRoot introuvable" }

$flag = Join-Path $bootRoot 'TELMI-BOOT-DIAG'
[System.IO.File]::WriteAllText($flag, '')
Write-Host " Flag OK -> $flag"

$active = Join-Path $bootRoot 'rf3536k3ka.dtb'
$diag = Join-Path $bootRoot 'dtb\y3506-bootdiag.dtb'
if (Test-Path $diag) {
    Copy-Item -Force $diag $active
    Write-Host " DTB    -> rf3536k3ka.dtb <= y3506-bootdiag.dtb"
} else {
    Write-Host ' WARN: dtb\y3506-bootdiag.dtb absent — copiez-le manuellement.'
}

Set-Content -Path (Join-Path $bootRoot 'TELMI-REV.txt') -Value 'y3506-bootdiag' -NoNewline -Encoding ascii
Set-Content -Path (Join-Path $bootRoot 'TELMI-AUDIO-PATH.txt') -Value 'HP' -NoNewline -Encoding ascii
Write-Host ' REV    -> y3506-bootdiag / AUDIO=HP'

Write-Host ''
Write-Host ' Boot 30-40s (ecran peut rester noir), puis relis BOOT :'
Write-Host '   telmi-boot-diag-VERDICT.txt'
Write-Host '   telmi-boot-diag.log'
Write-Host ''
