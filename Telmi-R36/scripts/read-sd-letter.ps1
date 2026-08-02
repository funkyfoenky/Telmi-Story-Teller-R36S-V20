# Methode alternative : lettre de lecteur (sans wsl --mount)
# PowerShell ADMINISTRATEUR
$ErrorActionPreference = 'Continue'

Write-Host "=== wsl --shutdown (debloque le montage) ==="
wsl --shutdown
Start-Sleep -Seconds 3

$sd = Get-Disk | Where-Object { $_.BusType -eq 'USB' -and $_.Size -gt 1GB -and $_.OperationalStatus -eq 'Online' } | Select-Object -First 1
if (-not $sd) {
    Write-Host "Carte SD non trouvee. Reinserez-la."
    Get-Disk | Format-Table Number, Size, OperationalStatus, BusType
    exit 1
}

$n = $sd.Number
Write-Host "Disque $n ($([int]($sd.Size/1GB)) Go)"

$part = Get-Partition -DiskNumber $n -PartitionNumber 1
if (-not $part.DriveLetter -or $part.DriveLetter -eq [char]0) {
    Write-Host "Attribution lettre T: a la partition BOOT..."
    Set-Partition -DiskNumber $n -PartitionNumber 1 -DriveLetter T
    Start-Sleep -Seconds 2
}

$bootLog = "T:\telmi-runtime.log"
$rootLog = "T:\..\." # ext4 pas lisible

Write-Host ""
if (Test-Path $bootLog) {
    Write-Host "========== telmi-runtime.log =========="
    Get-Content $bootLog
} else {
    Write-Host "Pas de $bootLog"
    Write-Host "Contenu de T:\"
    Get-ChildItem T:\ -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "La partition root (ext4) n'est pas lisible sous Windows."
Write-Host "Si le log BOOT est vide, essayez wsl --mount apres wsl --shutdown :"
Write-Host "  wsl --mount \\.\PHYSICALDRIVE$n --bare"
Write-Host "  wsl -u root bash /mnt/c/Users/Utilisateur/Downloads/Tools/HelloWorld_R36S/Telmi-R36/scripts/read-sd-wsl.sh"
