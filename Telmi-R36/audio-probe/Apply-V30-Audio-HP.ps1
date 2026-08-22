# Applique le correctif audio V30 (Playback Path=HP) sur la SD.
# Met a jour telmi-runtime.sh + storyTeller (ou storyTeller.real si wrapper probe).
$ErrorActionPreference = 'Stop'
# Ce script est dans audio-probe/ -> parent = Telmi-R36
$Telmi = Split-Path $PSScriptRoot -Parent
$Log = Join-Path $Telmi 'output\v30-hotfixes\inject-audio-hp.log'
$RuntimeSrc = Join-Path $Telmi 'overlay\opt\telmi\bin\telmi-runtime.sh'
$StorySrc = Join-Path $Telmi 'output\v30-hotfixes\storyTeller'
if (-not (Test-Path $StorySrc)) {
    $StorySrc = Join-Path $Telmi 'staging\v30\opt\telmi\bin\storyTeller'
}
New-Item -ItemType Directory -Force -Path (Split-Path $Log) | Out-Null

function Log([string]$m) {
    Add-Content -Path $Log -Value ('{0} {1}' -f (Get-Date -Format o), $m) -Encoding UTF8
    Write-Host $m
}

Set-Content -Path $Log -Value 'inject-audio-hp start' -Encoding UTF8
if (-not (Test-Path $RuntimeSrc)) { throw "missing runtime: $RuntimeSrc" }
if (-not (Test-Path $StorySrc)) { throw "missing storyTeller: compile d'abord (staging/v30 ou v30-hotfixes)" }

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
$TmpRoot   = Join-Path $env:TEMP 'telmi-sd-root-audiohp.ext4'

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
$wslStory = (wsl -e wslpath -a $StorySrc).Trim()
$wslRuntime = (wsl -e wslpath -a $RuntimeSrc).Trim()

$bash = @"
set -e
export LD_LIBRARY_PATH=$wslTelmi/.tools/lib:`${LD_LIBRARY_PATH:-}
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
W=`$(mktemp -d /tmp/sd-hp-XXXXXX)
mkdir -p "`$W/mnt"
$wslTelmi/.tools/fuse2fs -o fakeroot,rw "$wslTmp" "`$W/mnt"
sleep 1
BIN="`$W/mnt/opt/telmi/bin"
test -d "`$BIN"
cp -f "$wslRuntime" "`$BIN/telmi-runtime.sh"
chmod 755 "`$BIN/telmi-runtime.sh"
# Si wrapper probe present : maj storyTeller.real ; sinon storyTeller
if [ -f "`$BIN/storyTeller.real" ]; then
  cp -f "$wslStory" "`$BIN/storyTeller.real"
  chmod 755 "`$BIN/storyTeller.real"
  echo updated storyTeller.real
else
  cp -f "$wslStory" "`$BIN/storyTeller"
  chmod 755 "`$BIN/storyTeller"
  echo updated storyTeller
fi
mkdir -p "`$W/mnt/opt/telmi/telmiVersion"
echo -n v30 > "`$W/mnt/opt/telmi/telmiVersion/profile.txt"
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
Log 'DONE - desactive AUDIO-PROBE puis boot Telmi normal'
Write-Host ''
Write-Host ' Inject HP OK. Lance Disable-Audio-Probe.bat (ou efface D:\TELMI-AUDIO-PROBE), puis boot.'
