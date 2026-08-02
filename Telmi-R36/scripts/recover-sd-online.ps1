# Remet la carte SD en ligne apres un wsl --mount rate
# PowerShell ADMINISTRATEUR
Write-Host "Arret WSL..."
wsl --shutdown
Start-Sleep -Seconds 3

foreach ($d in 0..9) {
    wsl --unmount "\\.\PHYSICALDRIVE$d" 2>$null | Out-Null
}

$sd = Get-Disk | Where-Object { $_.BusType -eq 'USB' -and $_.Size -gt 1GB -and $_.OperationalStatus -ne 'No Media' } | Select-Object -First 1
if (-not $sd) {
    Write-Host "Carte SD non detectee. Reinserez-la."
    exit 1
}

$n = $sd.Number
Write-Host "Disque $n : $($sd.OperationalStatus), Offline=$($sd.IsOffline)"

if ($sd.IsOffline -or $sd.OperationalStatus -eq 'Offline') {
    Set-Disk -Number $n -IsOffline $false
    Start-Sleep -Seconds 1
}

# diskpart online
$dp = @"
select disk $n
online disk
attributes disk clear readonly
"@
$dp | diskpart

Get-Disk -Number $n | Format-Table Number, OperationalStatus, IsOffline
Write-Host "OK. Le disque devrait etre En ligne dans Gestion des disques."
