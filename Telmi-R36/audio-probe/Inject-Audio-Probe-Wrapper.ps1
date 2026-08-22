# Inject storyTeller wrapper + storyTeller.real into SD root (one-time).
# Layout Telmi V20/V30 compact : root @ sector 1056768, size 1536 MiB
$ErrorActionPreference = 'Stop'
$Telmi = Split-Path $PSScriptRoot -Parent
$Log = Join-Path $Telmi 'output\v30-hotfixes\inject-audio-probe.log'
$WrapperSrc = Join-Path $PSScriptRoot 'storyTeller-wrapper.sh'
$ProbeSrc = $PSScriptRoot
New-Item -ItemType Directory -Force -Path (Split-Path $Log) | Out-Null

function Log([string]$m) {
    Add-Content -Path $Log -Value ('{0} {1}' -f (Get-Date -Format o), $m) -Encoding UTF8
    Write-Host $m
}

Set-Content -Path $Log -Value 'inject-audio-probe start' -Encoding UTF8
if (-not (Test-Path $WrapperSrc)) { throw 'missing wrapper' }

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
$TmpRoot   = Join-Path $env:TEMP 'telmi-sd-root-audioprobe.ext4'

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
$wslProbe = (wsl -e wslpath -a $ProbeSrc).Trim()

$bash = @"
set -e
export LD_LIBRARY_PATH=$wslTelmi/.tools/lib:`${LD_LIBRARY_PATH:-}
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
W=`$(mktemp -d /tmp/sd-ap-XXXXXX)
mkdir -p "`$W/mnt"
$wslTelmi/.tools/fuse2fs -o fakeroot,rw "$wslTmp" "`$W/mnt"
sleep 1
test -d "`$W/mnt/opt/telmi/bin"
BIN="`$W/mnt/opt/telmi/bin"
# Preserve real binary once
if [ ! -f "`$BIN/storyTeller.real" ]; then
  cp -a "`$BIN/storyTeller" "`$BIN/storyTeller.real"
fi
# Install wrapper as storyTeller (shell script)
cp -f "$wslProbe/storyTeller-wrapper.sh" "`$BIN/storyTeller"
chmod 755 "`$BIN/storyTeller" "`$BIN/storyTeller.real"
# Also ship probe under /opt as fallback
mkdir -p "`$W/mnt/opt/telmi/audio-probe"
cp -f "$wslProbe/run.sh" "$wslProbe/tone.wav" "$wslProbe/fbcolor" "`$W/mnt/opt/telmi/audio-probe/"
chmod 755 "`$W/mnt/opt/telmi/audio-probe/run.sh" "`$W/mnt/opt/telmi/audio-probe/fbcolor"
# Updated runtime with AUDIO-PROBE hook
cp -f "$wslTelmi/overlay/opt/telmi/bin/telmi-runtime.sh" "`$W/mnt/opt/telmi/bin/telmi-runtime.sh"
chmod 755 "`$W/mnt/opt/telmi/bin/telmi-runtime.sh"
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
Log 'DONE - lance Enable-Audio-Probe.bat puis boot la console'
Write-Host ''
Write-Host ' Inject OK. Ensuite : Enable-Audio-Probe.bat (volume TELMI) puis boot.'
