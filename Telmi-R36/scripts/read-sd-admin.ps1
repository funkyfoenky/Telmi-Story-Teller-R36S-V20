# Diagnostic + lecture logs SD Telmi — PowerShell ADMINISTRATEUR
$ErrorActionPreference = 'Continue'

Write-Host "=== Disques ==="
Get-Disk | Format-Table Number, FriendlyName, Size, OperationalStatus, IsOffline, BusType

$sd = Get-Disk | Where-Object { $_.BusType -eq 'USB' -and $_.Size -gt 1GB -and $_.OperationalStatus -ne 'No Media' } | Select-Object -First 1

if (-not $sd) {
    Write-Host ""
    Write-Host "ERREUR: Aucune carte SD USB detectee."
    Write-Host "  - Reinserez la carte dans le lecteur"
    Write-Host "  - Verifiez qu'elle apparait dans Gestion des disques"
    exit 1
}

$n = $sd.Number
$phys = "\\.\PHYSICALDRIVE$n"
Write-Host ""
Write-Host "Carte SD = Disque $n ($phys), statut: $($sd.OperationalStatus), offline=$($sd.IsOffline)"

# Demontages WSL precedents (tous les disques USB possibles)
foreach ($d in 0..9) {
    wsl --unmount "\\.\PHYSICALDRIVE$d" 2>$null | Out-Null
}

if ($sd.IsOffline -or $sd.OperationalStatus -eq 'Offline') {
    Write-Host "Remise en ligne..."
    Set-Disk -Number $n -IsOffline $false
    Start-Sleep -Seconds 2
    $sd = Get-Disk -Number $n
    Write-Host "Nouveau statut: $($sd.OperationalStatus), offline=$($sd.IsOffline)"
}

Write-Host ""
Write-Host "Montage WSL de $phys ..."
$out = wsl --mount $phys --bare 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    Write-Host "ECHEC wsl --mount:"
    Write-Host $out
    Write-Host ""
    Write-Host "Solutions:"
    Write-Host "  1. Retirez la carte, attendez 5s, re-inserez"
    Write-Host "  2. Gestion des disques > Disque $n > clic droit > En ligne"
    Write-Host "  3. Fermez toutes les fenetres WSL: wsl --shutdown puis relancez ce script"
    exit 1
}

Start-Sleep -Seconds 2
Write-Host "OK. Lecture des logs..."
Write-Host ""

$sh = Join-Path $PSScriptRoot "read-sd-wsl.sh"
$shWsl = (wsl wslpath -a $sh).Trim()
wsl -u root bash $shWsl

Write-Host ""
Write-Host "Demontage..."
wsl --unmount $phys 2>$null | Out-Null
