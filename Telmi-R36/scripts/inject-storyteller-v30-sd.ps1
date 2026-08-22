# Inject storyTeller V30 into SD root WITHOUT wsl --mount
# Reads/writes PhysicalDrive2 partition 2 via offset (GPT Telmi V20 layout)
$ErrorActionPreference = "Stop"
$Log = "C:\Users\Utilisateur\Downloads\Tools\HelloWorld_R36S\Telmi-R36\output\v30-hotfixes\inject-sd.log"
$Telmi = "C:\Users\Utilisateur\Downloads\Tools\HelloWorld_R36S\Telmi-R36"
$StorySrc = Join-Path $Telmi "output\v30-hotfixes\storyTeller"
$DiskPath = "\\.\PhysicalDrive2"
# V20 layout
$RootStart = 1056768L * 512L
$RootSize  = 1536L * 1024L * 1024L
$TmpRoot   = Join-Path $env:TEMP "telmi-sd-root.ext4"

function Log([string]$m) {
    Add-Content -Path $Log -Value ("{0} {1}" -f (Get-Date -Format o), $m) -Encoding UTF8
    Write-Host $m
}

Set-Content -Path $Log -Value "inject-dd start" -Encoding UTF8
if (-not (Test-Path $StorySrc)) { Log "ERREUR missing storyTeller"; exit 1 }

Log "Extract root from $DiskPath offset=$RootStart size=$RootSize"
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
            if ($r -le 0) { throw "short read" }
            $out.Write($buf, 0, $r)
            $left -= $r
        }
    } finally { $out.Close() }
} finally { $fs.Close() }
Log "Extract OK -> $TmpRoot"

$wslTmp = (wsl -e wslpath -a $TmpRoot).Trim()
$wslStory = (wsl -e wslpath -a $StorySrc).Trim()
$wslTelmi = (wsl -e wslpath -a $Telmi).Trim()

$bash = @"
set -e
export LD_LIBRARY_PATH=$wslTelmi/.tools/lib:`${LD_LIBRARY_PATH:-}
W=`$(mktemp -d /tmp/sd-inj-XXXXXX)
mkdir -p "`$W/mnt"
$wslTelmi/.tools/fuse2fs -o fakeroot,rw "$wslTmp" "`$W/mnt"
sleep 1
test -d "`$W/mnt/opt/telmi/bin"
cp -a "`$W/mnt/opt/telmi/bin/storyTeller" "`$W/mnt/opt/telmi/bin/storyTeller.bak-v20" 2>/dev/null || true
cp -f "$wslStory" "`$W/mnt/opt/telmi/bin/storyTeller"
chmod +x "`$W/mnt/opt/telmi/bin/storyTeller"
mkdir -p "`$W/mnt/opt/telmi/telmiVersion"
echo -n v30 > "`$W/mnt/opt/telmi/telmiVersion/profile.txt"
sync
fusermount -u "`$W/mnt"
sleep 1
rm -rf "`$W"
echo OK fuse inject
"@
Log "fuse2fs inject..."
$bash | wsl -u root -e bash -s 2>&1 | ForEach-Object { Log $_ }

Log "Write root back to SD..."
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
            if ($r -le 0) { throw "short read tmp" }
            $fs.Write($buf, 0, $r)
            $left -= $r
        }
        $fs.Flush()
    } finally { $inp.Close() }
} finally { $fs.Close() }

Remove-Item $TmpRoot -Force -ErrorAction SilentlyContinue
Log "OK storyTeller V30 injecte sur SD"
exit 0
