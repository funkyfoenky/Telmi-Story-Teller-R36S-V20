$bootOffset = 16777216
$rootOffset = 541065216
$outBoot = "$env:TEMP\sd-boot-part.img"
$outRoot = "$env:TEMP\sd-root-part.img"

try {
    $fs = [IO.File]::Open('\\.\PHYSICALDRIVE2', [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
} catch {
    Write-Error "Impossible d'ouvrir PHYSICALDRIVE2 (admin requis ?): $_"
    exit 1
}

function Copy-Part($offset, $size, $path) {
    $fs.Seek($offset, [IO.SeekOrigin]::Begin) | Out-Null
    $buf = New-Object byte[] 1048576
    $left = [int64]$size
    $out = [IO.File]::Create($path)
    while ($left -gt 0) {
        $chunk = [Math]::Min($buf.Length, $left)
        $read = $fs.Read($buf, 0, [int]$chunk)
        if ($read -le 0) { break }
        $out.Write($buf, 0, $read)
        $left -= $read
    }
    $out.Close()
    Write-Host "Extrait $path ($size octets)"
}

Copy-Part $bootOffset 524288000 $outBoot
Copy-Part $rootOffset 1606401536 $outRoot
$fs.Close()
Write-Host "OK"
