#Requires -Version 5
$ErrorActionPreference = 'Stop'

Write-Host ''
Write-Host ' Telmi - Activer PANEL DIAG (MIPI ON, logs BOOT)'
Write-Host ' ================================================='
Write-Host ' Necessite image >= 0.6.8'
Write-Host ' Le DTB panel reste actif (ex. y3506-v05d.dtb)'
Write-Host ' NE PAS confondre avec TELMI-BOOT-DIAG (DSI off)'
Write-Host ''

$vols = @(Get-Volume | Where-Object { $_.DriveLetter -and $_.FileSystemLabel -eq 'BOOT' })
if ($vols.Count -eq 1) { $boot = $vols[0] }
elseif ($vols.Count -gt 1) {
    for ($i = 0; $i -lt $vols.Count; $i++) { Write-Host ("  [{0}] {1}:" -f ($i+1), $vols[$i].DriveLetter) }
    $n = [int](Read-Host 'Choix')
    $boot = $vols[$n - 1]
} else {
    $l = (Read-Host 'Lettre BOOT').Trim().TrimEnd(':')
    $boot = Get-Volume -DriveLetter $l
}

$root = ("{0}:\" -f $boot.DriveLetter)
$flag = Join-Path $root 'TELMI-PANEL-DIAG'
[System.IO.File]::WriteAllText($flag, '')
Write-Host " Flag OK -> $flag"

foreach ($old in @('telmi-panel-diag.log', 'telmi-panel-diag-VERDICT.txt', 'telmi-panic-prev.log')) {
    $p = Join-Path $root $old
    if (Test-Path $p) { Remove-Item -Force $p; Write-Host " Ancien $old supprime" }
}

Write-Host ''
Write-Host ' Apres boot (meme si ecran noir / OFF), relire BOOT :'
Write-Host '   telmi-panel-diag.log          (si userspace a demarre)'
Write-Host '   telmi-panel-diag-VERDICT.txt'
Write-Host '   telmi-panic-prev.log          (panic noyau boot PRECEDENT)'
Write-Host ''
