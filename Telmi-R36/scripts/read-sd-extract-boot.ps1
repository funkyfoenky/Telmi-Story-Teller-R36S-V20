# Extrait la partition BOOT (500 Mo) et lit telmi-runtime.log — ADMIN
$ErrorActionPreference = 'Stop'

function To-WslPath([string]$winPath) {
    $full = [IO.Path]::GetFullPath($winPath)
    $drive = $full.Substring(0, 1).ToLower()
    $rest = $full.Substring(2).Replace('\', '/')
    return "/mnt/$drive$rest"
}

$sd = Get-Disk | Where-Object { $_.BusType -eq 'USB' -and $_.Size -gt 1GB -and $_.OperationalStatus -eq 'Online' } | Select-Object -First 1
if (-not $sd) { Write-Error "Carte SD en ligne introuvable. Lancez recover-sd-online.ps1 d'abord." }

$n = $sd.Number
$part = Get-Partition -DiskNumber $n -PartitionNumber 1
$out = [IO.Path]::GetFullPath("$env:TEMP\sd-boot-part.img")

Write-Host "Extraction partition BOOT (disque $n)..."
$fs = [IO.File]::Open("\\.\PHYSICALDRIVE$n", [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
$fs.Seek($part.Offset, [IO.SeekOrigin]::Begin) | Out-Null
$buf = New-Object byte[] 1048576
$left = [int64]$part.Size
$sw = [IO.File]::Create($out)
while ($left -gt 0) {
    $chunk = [Math]::Min($buf.Length, $left)
    $read = $fs.Read($buf, 0, [int]$chunk)
    if ($read -le 0) { break }
    $sw.Write($buf, 0, $read)
    $left -= $read
}
$sw.Close()
$fs.Close()

$outWsl = To-WslPath $out
Write-Host "Fichier: $out"
Write-Host ""
Write-Host "=== Lecture via WSL ==="
wsl -u root bash -c "mkdir -p /mnt/sdfile; umount /mnt/sdfile 2>/dev/null; mount -o loop,ro '$outWsl' /mnt/sdfile && ls -la /mnt/sdfile/ && echo '--- LOG ---' && cat /mnt/sdfile/telmi-runtime.log 2>/dev/null || echo 'log absent ou vide' && umount /mnt/sdfile"
