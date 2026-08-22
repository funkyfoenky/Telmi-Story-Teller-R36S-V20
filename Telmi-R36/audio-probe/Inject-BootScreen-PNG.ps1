# Injecte bootScreen (PNG) + assets/res sur la SD root (sans image 2Go).
$ErrorActionPreference = 'Stop'
$Telmi = Split-Path $PSScriptRoot -Parent
$Log = Join-Path $Telmi 'output\v30-hotfixes\inject-bootscreen.log'
$BootSrc = Join-Path $Telmi 'staging\v30\opt\telmi\bin\bootScreen'
if (-not (Test-Path $BootSrc)) { $BootSrc = Join-Path $Telmi 'staging\opt\telmi\bin\bootScreen' }
$ResSrc = Join-Path $Telmi 'assets\res'
New-Item -ItemType Directory -Force -Path (Split-Path $Log) | Out-Null

function Log([string]$m) {
    Add-Content -Path $Log -Value ('{0} {1}' -f (Get-Date -Format o), $m) -Encoding UTF8
    Write-Host $m
}

Set-Content -Path $Log -Value 'inject-bootscreen start' -Encoding UTF8
if (-not (Test-Path $BootSrc)) { throw "missing bootScreen: rebuild with build-telmi-bins.sh v30 bootScreen" }
if (-not (Test-Path $ResSrc)) { throw "missing assets/res" }

Write-Host ''
Write-Host ' Disques physiques :'
Get-CimInstance Win32_DiskDrive | ForEach-Object {
    Write-Host ('  PhysicalDrive{0}  {1}  {2:N1} Go' -f $_.Index, $_.Model, ($_.Size/1GB))
}
Write-Host ''
$idx = (Read-Host 'Numero PhysicalDrive de la SD Telmi (ex: 2)').Trim()
if ($idx -notmatch '^\d+$') { throw 'index invalide' }
$DiskPath = "\\.\PhysicalDrive$idx"

$RootStart = 1056768L * 512L
$RootSize  = 1536L * 1024L * 1024L
$TmpRoot   = Join-Path $env:TEMP 'telmi-sd-root-bootscreen.ext4'

Log "Extract root from $DiskPath"
$fs = [System.IO.File]::Open($DiskPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)
try {
    $null = $fs.Seek($RootStart, [System.IO.SeekOrigin]::Begin)
    $out = [System.IO.File]::Create($TmpRoot)
    try {
        $buf = New-Object byte[] (4MB)
        $left = $RootSize
        while ($left -gt 0) {
            $n = [Math]::Min($buf.Length, $left)
            $r = $fs.Read($buf, 0, $n)
            if ($r -le 0) { throw 'short read' }
            $out.Write($buf, 0, $r)
            $left -= $r
        }
    } finally { $out.Close() }
} finally { $fs.Close() }
Log 'Extract OK'

$wslTmp = (wsl -e wslpath -a $TmpRoot).Trim()
$wslTelmi = (wsl -e wslpath -a $Telmi).Trim()
$wslBoot = (wsl -e wslpath -a $BootSrc).Trim()
$wslRes = (wsl -e wslpath -a $ResSrc).Trim()

$bash = @"
set -e
export LD_LIBRARY_PATH=$wslTelmi/.tools/lib:`${LD_LIBRARY_PATH:-}
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
W=`$(mktemp -d /tmp/sd-bs-XXXXXX)
mkdir -p "`$W/mnt"
$wslTelmi/.tools/fuse2fs -o fakeroot,rw "$wslTmp" "`$W/mnt"
sleep 1
BIN="`$W/mnt/opt/telmi/bin"
RES="`$W/mnt/opt/telmi/res"
test -d "`$BIN"
cp -f "$wslBoot" "`$BIN/bootScreen"
chmod 755 "`$BIN/bootScreen"
mkdir -p "`$RES"
rsync -a "$wslRes/" "`$RES/"
sync
fusermount -u "`$W/mnt" || true
sleep 1
rm -rf "`$W"
echo OK fuse inject
"@
Log 'fuse2fs inject...'
$bash | wsl -e bash -s 2>&1 | ForEach-Object { Log "$_" }

Log 'Write root back...'
$fs = [System.IO.File]::Open($DiskPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)
try {
    $null = $fs.Seek($RootStart, [System.IO.SeekOrigin]::Begin)
    $inp = [System.IO.File]::OpenRead($TmpRoot)
    try {
        $buf = New-Object byte[] (4MB)
        $left = $RootSize
        while ($left -gt 0) {
            $n = [Math]::Min($buf.Length, $left)
            $r = $inp.Read($buf, 0, $n)
            if ($r -le 0) { throw 'short read tmp' }
            $fs.Write($buf, 0, $r)
            $left -= $r
        }
    } finally { $inp.Close() }
} finally { $fs.Close() }

Remove-Item -Force $TmpRoot -ErrorAction SilentlyContinue
Log 'DONE - boot et teste les ecrans Boot / End'
Write-Host ''
Write-Host ' Inject bootScreen OK. Boot la console : tu dois voir les PNG (pas juste violet/noir).'
