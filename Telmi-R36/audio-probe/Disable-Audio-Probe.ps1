$ErrorActionPreference = 'Stop'
Write-Host 'Desactiver AUDIO PROBE (supprime les flags TELMI et BOOT).'
$telmi = (Read-Host 'Lettre volume TELMI (ex: E)').Trim().TrimEnd(':')
$boot = (Read-Host 'Lettre volume BOOT (ex: D, Entrée si inconnu)').Trim().TrimEnd(':')

$removed = $false
if ($telmi -match '^[A-Za-z]$') {
    $f = "${telmi}:\AUDIO-PROBE"
    if (Test-Path $f) { Remove-Item -Force $f; Write-Host "Supprime $f"; $removed = $true }
}
if ($boot -match '^[A-Za-z]$') {
    $f = "${boot}:\TELMI-AUDIO-PROBE"
    if (Test-Path $f) { Remove-Item -Force $f; Write-Host "Supprime $f"; $removed = $true }
} else {
    # Auto: volumes labelles BOOT
    Get-Volume | Where-Object { $_.FileSystemLabel -eq 'BOOT' -and $_.DriveLetter } | ForEach-Object {
        $f = "$($_.DriveLetter):\TELMI-AUDIO-PROBE"
        if (Test-Path $f) { Remove-Item -Force $f; Write-Host "Supprime $f"; $script:removed = $true }
    }
}
if (-not $removed) { Write-Host 'Aucun flag trouve.' }
else { Write-Host 'Prochain boot = Telmi normal.' }
