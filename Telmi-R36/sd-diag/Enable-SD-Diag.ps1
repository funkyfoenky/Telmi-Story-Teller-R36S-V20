# Cree le flag TELMI-SD-DIAG sur le volume BOOT (carte OS).
#Requires -Version 5
$ErrorActionPreference = 'Stop'

Write-Host ''
Write-Host ' Telmi V30 - Activer SD DIAG'
Write-Host ' ============================'
Write-Host ' Volume BOOT = partition FAT de la carte OS (Image, DTB, TELMI-REV.txt).'
Write-Host ''
$letter = (Read-Host 'Lettre du volume BOOT (ex: D)').Trim().TrimEnd(':')
if ($letter -notmatch '^[A-Za-z]$') { throw 'Lettre invalide' }
$bootRoot = "${letter}:"
if (-not (Test-Path $bootRoot)) { throw "Lecteur $bootRoot introuvable" }

$flag = Join-Path $bootRoot 'TELMI-SD-DIAG'
[System.IO.File]::WriteAllText($flag, '')
Write-Host " Flag OK -> $flag"

$rev = Join-Path $bootRoot 'TELMI-REV.txt'
if (Test-Path $rev) {
    $r = (Get-Content $rev -Raw).Trim()
    Write-Host " TELMI-REV = $r"
    if ($r -notmatch '(?i)^v30') {
        Write-Host ' WARN: REV n est pas v30* — le diag sera ignore au boot.'
        Write-Host ' Lance Select-Telmi-REV.bat -> v30-panel4 avant de tester.'
    }
} else {
    Write-Host ' WARN: TELMI-REV.txt absent — Select-Telmi-REV.bat requis.'
}

Write-Host ''
Write-Host ' Pret. Ejecte la SD OS, mets contenu a gauche, boot.'
Write-Host ' Apres extinction : lis BOOT:\telmi-sd-diag-VERDICT.txt'
Write-Host ''
