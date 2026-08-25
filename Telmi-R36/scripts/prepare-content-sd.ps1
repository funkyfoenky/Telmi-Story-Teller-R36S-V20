# Prepare carte CONTENU Telmi (slot gauche R36S) - FAT32 label TELMI pour Telmi Sync.
#
# Usage :
#   powershell -File prepare-content-sd.ps1
#   powershell -File prepare-content-sd.ps1 -DiskNumber 2 -Yes

#Requires -RunAsAdministrator
param(
    [int]$DiskNumber = -1,
    [switch]$Yes
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$TelmiR36 = Split-Path -Parent $ScriptDir
$ContentDir = Join-Path $TelmiR36 'content'
. (Join-Path $ScriptDir 'telmi-sd-common.ps1')

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' TelmiOS - Prepare carte CONTENU (slot gauche)' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' Cette carte est pour Stories/Music/Saves + Telmi Sync.'
Write-Host ' L OS reste sur la SD du slot DROIT (Flash-Telmi-SD.bat -Mode os-only).'
Write-Host ''

$disks = @(Get-RemovableDisks)
if ($disks.Count -eq 0) {
    Write-Host 'Aucun disque amovible.' -ForegroundColor Red
    exit 1
}

if ($DiskNumber -ge 0) {
    $disk = Get-Disk -Number $DiskNumber -EA Stop
} else {
    Write-Host ' Disques amovibles :'
    $map = @{}; $i = 1
    foreach ($d in $disks) {
        Write-Host ("  [{0}] PhysicalDrive{1}  {2}  {3}" -f $i, $d.Number, (Format-SizeGB $d.Size), $d.FriendlyName)
        $map[$i] = $d; $i++
    }
    Write-Host ''
    $sel = (Read-Host 'Numero (ou Q)').Trim()
    if ($sel -eq 'Q' -or $sel -eq 'q') { exit 0 }
    $n = 0
    if (-not [int]::TryParse($sel, [ref]$n) -or -not $map.ContainsKey($n)) { throw 'Choix invalide' }
    $disk = $map[$n]
}

$diskNum = [int]$disk.Number
Write-Host (" Cible : PhysicalDrive{0} ({1})" -f $diskNum, (Format-SizeGB $disk.Size)) -ForegroundColor Yellow
Write-Host ' ATTENTION : toutes les partitions seront effacees.' -ForegroundColor Red

if (-not $Yes) {
    $c = Read-Host 'Tapez PREPARE pour confirmer'
    if ($c -ne 'PREPARE') { Write-Host 'Annule.'; exit 0 }
}

Set-TelmiAutomount -enable $false
try {
    $vol = Initialize-TelmiContentDisk -diskNum $diskNum
    $driveRoot = '{0}:\' -f $vol.DriveLetter
    Seed-TelmiContentTree -DriveRoot $driveRoot -ContentDir $ContentDir -TelmiR36 $TelmiR36 -ContentOnlyStub
    try { Set-Volume -DriveLetter $vol.DriveLetter -NewFileSystemLabel 'TELMI' -EA SilentlyContinue } catch {}
    Write-Host ''
    Write-Host (" Carte contenu prete sur {0} (label TELMI)" -f $driveRoot) -ForegroundColor Green
    Write-Host ' Inserez-la dans le slot GAUCHE de la R36S.' -ForegroundColor Green
} finally {
    Set-TelmiAutomount -enable $true
}
