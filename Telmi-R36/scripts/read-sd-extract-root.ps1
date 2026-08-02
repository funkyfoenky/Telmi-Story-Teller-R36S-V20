# Extrait la partition root ext4 et lit telmi/logs/runtime.log — ADMIN
$ErrorActionPreference = 'Stop'

function To-WslPath([string]$winPath) {
    $full = [IO.Path]::GetFullPath($winPath)
    $drive = $full.Substring(0, 1).ToLower()
    $rest = $full.Substring(2).Replace('\', '/')
    return "/mnt/$drive$rest"
}

$sd = Get-Disk | Where-Object { $_.BusType -eq 'USB' -and $_.Size -gt 1GB -and $_.OperationalStatus -eq 'Online' } | Select-Object -First 1
if (-not $sd) { Write-Error "Carte SD en ligne introuvable." }

$n = $sd.Number
$part = Get-Partition -DiskNumber $n -PartitionNumber 2
$out = [IO.Path]::GetFullPath("$env:TEMP\sd-root-part.img")

Write-Host "Extraction partition root (disque $n)..."
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
Write-Host "WSL: $outWsl"
Write-Host ""

wsl -u root bash -c @"
mkdir -p /mnt/sdroot
umount /mnt/sdroot 2>/dev/null
mount -o loop,ro '$outWsl' /mnt/sdroot
echo '=== init.d ==='
ls /mnt/sdroot/etc/init.d/
echo '=== LOG BOOT (partition 1) ==='
cat /mnt/sdroot/boot/telmi-runtime.log 2>/dev/null || echo 'absent'
echo '=== init.d S99telmi (head) ==='
head -3 /mnt/sdroot/etc/init.d/S99telmi 2>/dev/null | cat -A
echo '=== LOG runtime ==='
cat /mnt/sdroot/telmi/logs/runtime.log 2>/dev/null || echo 'absent'
echo '=== hello-world? ==='
ls /mnt/sdroot/usr/bin/hello-world 2>/dev/null || echo 'non'
echo '=== telmi bins ==='
ls /mnt/sdroot/opt/telmi/bin/ 2>/dev/null
umount /mnt/sdroot
"@
