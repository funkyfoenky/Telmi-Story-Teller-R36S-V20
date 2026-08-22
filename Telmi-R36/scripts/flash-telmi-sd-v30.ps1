# Flash TelmiOS profil V30 - delegue au flash interactif (usbipd + selection disque).
# Ne lit JAMAIS LATEST.txt (reserve au profil V20).
#
# Usage :
#   powershell -File flash-telmi-sd-v30.ps1
#   powershell -File flash-telmi-sd-v30.ps1 -DiskNumber 2 -Yes
#   powershell -File flash-telmi-sd-v30.ps1 -DriveLetter E -Yes

#Requires -RunAsAdministrator
param(
    [int]$DiskNumber = -1,
    [string]$DriveLetter = '',
    [ValidateSet('from-image', 'expand', 'full')]
    [string]$Mode = 'from-image',
    [switch]$Yes,
    [string]$ProgressFile = ''
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$MainFlash = Join-Path $ScriptDir 'flash-telmi-sd.ps1'

$argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $MainFlash, '-Profile', 'v30', '-Mode', $Mode)
if ($DiskNumber -ge 0) { $argsList += @('-DiskNumber', "$DiskNumber") }
if ($DriveLetter) { $argsList += @('-DriveLetter', $DriveLetter) }
if ($Yes) { $argsList += '-Yes' }
if ($ProgressFile) { $argsList += @('-ProgressFile', $ProgressFile) }

Write-Host ''
Write-Host ' TelmiOS profil V30 - flash interactif' -ForegroundColor Cyan
Write-Host ' (utilise LATEST-V30.txt / telmi-r36-v30-*.img)' -ForegroundColor DarkGray
Write-Host ''

& powershell @argsList
exit $LASTEXITCODE
