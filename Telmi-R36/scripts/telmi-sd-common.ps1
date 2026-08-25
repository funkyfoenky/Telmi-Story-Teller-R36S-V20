# Bibliotheque partagee : flash OS / prepare carte contenu (Windows natif)
$ErrorActionPreference = 'Stop'

if (-not ('TelmiDiskIO' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TelmiDiskIO {
    public const uint GENERIC_READ = 0x80000000;
    public const uint GENERIC_WRITE = 0x40000000;
    public const uint FILE_SHARE_READ = 0x1;
    public const uint FILE_SHARE_WRITE = 0x2;
    public const uint OPEN_EXISTING = 3;
    public const uint FILE_FLAG_WRITE_THROUGH = 0x80000000;
    public const uint FSCTL_LOCK_VOLUME = 0x00090018;
    public const uint FSCTL_DISMOUNT_VOLUME = 0x00090020;
    public static readonly IntPtr INVALID = new IntPtr(-1);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateFile(string lpFileName, uint dwDesiredAccess,
        uint dwShareMode, IntPtr lpSecurityAttributes, uint dwCreationDisposition,
        uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool DeviceIoControl(IntPtr hDevice, uint dwIoControlCode,
        IntPtr lpInBuffer, uint nInBufferSize, IntPtr lpOutBuffer, uint nOutBufferSize,
        out uint lpBytesReturned, IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool WriteFile(IntPtr hFile, byte[] lpBuffer, uint nNumberOfBytesToWrite,
        out uint lpNumberOfBytesWritten, IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool ReadFile(IntPtr hFile, byte[] lpBuffer, uint nNumberOfBytesToRead,
        out uint lpNumberOfBytesRead, IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetFilePointerEx(IntPtr hFile, long liDistanceToMove,
        out long lpNewFilePointer, uint dwMoveMethod);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool FlushFileBuffers(IntPtr hFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);

    public static void LockAndDismountLetter(char letter) {
        IntPtr h = LockVolumeLetter(letter);
        if (h != INVALID) CloseHandle(h);
    }

    // Garde le handle ouvert : le verrou tient jusqu a CloseHandle (critique pendant le dd)
    public static IntPtr LockVolumeLetter(char letter) {
        string path = "\\\\.\\" + letter + ":";
        IntPtr h = CreateFile(path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
            IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
        if (h == INVALID) return INVALID;
        uint br;
        DeviceIoControl(h, FSCTL_LOCK_VOLUME, IntPtr.Zero, 0, IntPtr.Zero, 0, out br, IntPtr.Zero);
        DeviceIoControl(h, FSCTL_DISMOUNT_VOLUME, IntPtr.Zero, 0, IntPtr.Zero, 0, out br, IntPtr.Zero);
        return h;
    }
}
'@
}

if (-not ('TelmiFmifs' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TelmiFmifs {
    public const int FmMediaRemovable = 11;
    public const int FmMediaFixed = 12;
    public const uint CbDone = 11;
    public static bool LastSuccess = false;
    public delegate bool FormatExCallback(uint command, uint modifier, IntPtr argument);

    [DllImport("fmifs.dll", CharSet = CharSet.Unicode)]
    public static extern void FormatEx(string driveRoot, int mediaFlag, string format,
        string label, bool quickFormat, int clusterSize, FormatExCallback callback);

    public static bool OnFormat(uint command, uint modifier, IntPtr argument) {
        if (command == CbDone && argument != IntPtr.Zero)
            LastSuccess = Marshal.ReadByte(argument) != 0;
        return true;
    }

    public static bool TryFormatFat32(string root, string label, int mediaFlag, int clusterSize) {
        LastSuccess = false;
        FormatExCallback cb = OnFormat;
        FormatEx(root, mediaFlag, "FAT32", label, true, clusterSize, cb);
        return LastSuccess;
    }
}
'@
}

function Format-SizeGB([int64]$b) { '{0:N1} Go' -f ($b / 1GB) }

function Get-RemovableDisks {
    Get-Disk | Where-Object {
        -not $_.IsBoot -and -not $_.IsSystem -and $_.Number -ne 0 -and
        $_.Size -ge 3GB -and $_.Size -le 2TB -and $_.OperationalStatus -eq 'Online' -and
        ($_.BusType -eq 'USB' -or $_.BusType -eq 'SD' -or $_.BusType -eq 'MMC' -or
         ($_.BusType -eq 'Unknown' -and $_.FriendlyName -match 'MassStorage|Mass Storage|Card Reader|SDHC|SDXC|MMC'))
    }
}

function Dismount-DiskVolumes([int]$num) {
    Get-Partition -DiskNumber $num -EA SilentlyContinue | ForEach-Object {
        if ($_.DriveLetter) {
            $ch = [char]$_.DriveLetter
            try { [TelmiDiskIO]::LockAndDismountLetter($ch) } catch {}
            try { mountvol ("{0}:" -f $ch) /D 2>$null } catch {}
        }
    }
    Start-Sleep -Milliseconds 300
}

function Set-TelmiAutomount([bool]$enable) {
    if ($enable) { mountvol /E | Out-Null } else { mountvol /N | Out-Null }
}

function Clear-TelmiDisk([int]$num) {
    Write-Host ("==> Nettoyage complet du disque {0}..." -f $num)
    Dismount-DiskVolumes -num $num
    try { Set-Disk -Number $num -IsOffline $false -EA SilentlyContinue } catch {}
    try { Set-Disk -Number $num -IsReadOnly $false -EA SilentlyContinue } catch {}
    Start-Sleep -Milliseconds 400
    $ok = $false
    try {
        Clear-Disk -Number $num -RemoveData -RemoveOEM -Confirm:$false -EA Stop
        $ok = $true
        Write-Host '  Clear-Disk OK'
    } catch {
        Write-Host ("  Clear-Disk: {0}" -f $_.Exception.Message)
    }
    if (-not $ok) {
        @"
select disk $num
online disk
attributes disk clear readonly
clean
"@ | diskpart | Out-Null
        Write-Host '  diskpart clean OK'
    }
    Start-Sleep -Seconds 1
    'rescan' | diskpart | Out-Null
}

function Format-TelmiFat32([char]$DriveLetter, [int64]$SizeBytes) {
    $drive = '{0}:' -f $DriveLetter
    $root = '{0}:\' -f $DriveLetter
    $limit32 = 32L * 1024L * 1024L * 1024L
    if ($SizeBytes -le $limit32) {
        try {
            Format-Volume -DriveLetter $DriveLetter -FileSystem FAT32 -NewFileSystemLabel 'TELMI' -Force -Confirm:$false | Out-Null
            $v = Get-Volume -DriveLetter $DriveLetter -EA SilentlyContinue
            if ($v -and $v.FileSystem -eq 'FAT32') { return $true }
        } catch {}
    }
    try { [TelmiDiskIO]::LockAndDismountLetter($DriveLetter) } catch {}
    Start-Sleep -Milliseconds 400
    foreach ($media in @([TelmiFmifs]::FmMediaRemovable, [TelmiFmifs]::FmMediaFixed)) {
        foreach ($cs in @(0, 32768, 65536)) {
            try {
                if ([TelmiFmifs]::TryFormatFat32($root, 'TELMI', [int]$media, [int]$cs)) {
                    Start-Sleep -Seconds 1
                    $v = Get-Volume -DriveLetter $DriveLetter -EA SilentlyContinue
                    if ($v -and $v.FileSystem -eq 'FAT32') { return $true }
                    return $true
                }
            } catch {}
        }
    }
    $ff = Join-Path $PSScriptRoot 'tools\fat32format.exe'
    if (Test-Path $ff) {
        $p = Start-Process -FilePath $ff -ArgumentList @('-y', $drive) -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -eq 0) { return $true }
    }
    return $false
}

function Seed-TelmiContentTree {
    param(
        [string]$DriveRoot,
        [string]$ContentDir,
        [string]$TelmiR36,
        [switch]$ContentOnlyStub
    )
    Write-Host '==> Arborescence TELMI'
    $dirs = @(
        'Stories', 'Music', 'Games', 'Saves', 'Saves\Stories', 'logs', 'config',
        'Games\gb', 'Games\gbc', 'Games\gba', 'Games\nes', 'Games\md', 'Games\snes', 'Games\psx'
    )
    foreach ($d in $dirs) {
        New-Item -ItemType Directory -Force -Path (Join-Path $DriveRoot $d) | Out-Null
    }
    foreach ($d in @('gb', 'gbc', 'gba', 'nes', 'md', 'snes', 'psx')) {
        $keep = Join-Path $DriveRoot "Games\$d\.keep"
        if (-not (Test-Path $keep)) { New-Item -ItemType File -Force -Path $keep | Out-Null }
    }
    if ($ContentDir -and (Test-Path $ContentDir)) {
        Copy-Item -Path (Join-Path $ContentDir '*') -Destination $DriveRoot -Recurse -Force -EA SilentlyContinue
    }
    $sysJson = Join-Path $TelmiR36 'assets\res\miyoo283_system.json'
    if ((Test-Path $sysJson) -and -not (Test-Path (Join-Path $DriveRoot 'system.json'))) {
        Copy-Item -Force $sysJson (Join-Path $DriveRoot 'system.json')
    }
    if (-not (Test-Path (Join-Path $DriveRoot 'autorun.inf'))) {
        Set-Content -Path (Join-Path $DriveRoot 'autorun.inf') -Encoding ASCII -Value @"
[autorun]
icon  = .tmp_update/res/sdcard.ico
label = TelmiOS-v1.10.1
"@
    }
    if ($ContentOnlyStub) {
        $stubRes = Join-Path $DriveRoot '.tmp_update\res'
        New-Item -ItemType Directory -Force -Path $stubRes | Out-Null
        $icoSrc = Join-Path $TelmiR36 'assets\res\sdcard.ico'
        if (Test-Path $icoSrc) { Copy-Item -Force $icoSrc (Join-Path $stubRes 'sdcard.ico') }
        $verDir = Join-Path $DriveRoot '.tmp_update\telmiVersion'
        New-Item -ItemType Directory -Force -Path $verDir | Out-Null
        Set-Content -Path (Join-Path $verDir 'content-only.txt') -Encoding ASCII -Value 'R36S dual-SD content (slot gauche)'
        Set-Content -Path (Join-Path $DriveRoot 'README.txt') -Encoding UTF8 -Value @"
TelmiOS - carte CONTENU (slot gauche R36S)

Stories/  Music/  Games/  Saves/
Sync Telmi Sync sur PC avec cette carte.
OS Telmi sur la SD du slot droit uniquement.
"@
    }
}

function Initialize-TelmiContentDisk([int]$diskNum) {
    Clear-TelmiDisk -num $diskNum
    Update-Disk -Number $diskNum -EA SilentlyContinue
    Start-Sleep -Seconds 1
    $part = New-Partition -DiskNumber $diskNum -UseMaximumSize -AssignDriveLetter
    $letter = $part.DriveLetter
    if (-not $letter) {
        $part = Get-Partition -DiskNumber $diskNum -PartitionNumber $part.PartitionNumber
        $letter = $part.DriveLetter
    }
    if (-not $letter) {
        Add-PartitionAccessPath -DiskNumber $diskNum -PartitionNumber $part.PartitionNumber -AssignDriveLetter
        $letter = (Get-Partition -DiskNumber $diskNum -PartitionNumber $part.PartitionNumber).DriveLetter
    }
    if (-not $letter) { throw 'Impossible d assigner une lettre au volume TELMI' }
    $volSize = [int64](Get-Partition -DiskNumber $diskNum -PartitionNumber $part.PartitionNumber).Size
    if (-not (Format-TelmiFat32 -DriveLetter $letter -SizeBytes $volSize)) {
        throw ("Format FAT32 echoue sur {0}:" -f $letter)
    }
    return [pscustomobject]@{ DriveLetter = $letter; SizeBytes = $volSize }
}
