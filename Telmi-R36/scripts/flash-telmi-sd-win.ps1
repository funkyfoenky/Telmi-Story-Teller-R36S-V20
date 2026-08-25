# Flash TelmiOS + expand TELMI  -  100% Windows (pas de WSL / usbipd).
#
# Usage :
#   powershell -File flash-telmi-sd-win.ps1
#   powershell -File flash-telmi-sd-win.ps1 -DiskNumber 2 -Yes
#   powershell -File flash-telmi-sd-win.ps1 -Mode expand -DiskNumber 2 -Yes
#
# Modes :
#   from-image  ecrit LATEST.img puis recree TELMI sur tout l'espace restant (single-SD legacy)
#   os-only     flash OS sans expand p3 (dual-SD : contenu sur slot gauche)
#   expand      recree seulement p3 TELMI (apres Rufus / flash partiel)

#Requires -RunAsAdministrator
param(
    [int]$DiskNumber = -1,
    [ValidateSet('from-image', 'os-only', 'expand')]
    [string]$Mode = 'from-image',
    [switch]$Yes,
    [string]$ImagePath = ''
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$TelmiR36 = Split-Path -Parent $ScriptDir
. (Join-Path $ScriptDir 'telmi-sd-common.ps1')
$OutputDir = Join-Path $TelmiR36 'output'
$ContentDir = Join-Path $TelmiR36 'content'
$LatestFile = Join-Path $OutputDir 'LATEST.txt'
$VersionFile = Join-Path $TelmiR36 'VERSION'

# Layout image compacte Telmi (secteurs 512)
$RootPartStart = 1056768L
$RootPartSizeMb = 1536L
$RootPartSectors = $RootPartSizeMb * 1024L * 1024L / 512L
$RootPartEnd = $RootPartStart + $RootPartSectors - 1L

function Get-LatestImage {
    if ($ImagePath -and (Test-Path $ImagePath)) { return (Resolve-Path $ImagePath).Path }
    if (Test-Path $LatestFile) {
        $n = (Get-Content $LatestFile -Raw).Trim()
        $p = Join-Path $OutputDir $n
        if (Test-Path $p) { return $p }
    }
    $imgs = @(Get-ChildItem $OutputDir -Filter 'telmi-r36-*.img' -EA SilentlyContinue |
        Where-Object { $_.Name -notmatch 'telmi-r36-v30-' } |
        Sort-Object LastWriteTime -Descending)
    if ($imgs.Count -gt 0) { return $imgs[0].FullName }
    return $null
}

function Format-SizeGB([int64]$b) {
    '{0:N1} Go' -f ($b / 1GB)
}

function Get-RemovableDisks {
    # Jamais le disque systeme / boot ; eviter le match "SD" dans les modeles NVMe (ex. SDBPNPZ)
    Get-Disk | Where-Object {
        -not $_.IsBoot -and
        -not $_.IsSystem -and
        $_.Number -ne 0 -and
        $_.Size -ge 3GB -and
        $_.Size -le 2TB -and
        $_.OperationalStatus -eq 'Online' -and
        ($_.BusType -eq 'USB' -or $_.BusType -eq 'SD' -or $_.BusType -eq 'MMC' -or
         ($_.BusType -eq 'Unknown' -and $_.FriendlyName -match 'MassStorage|Mass Storage|Card Reader|SDHC|SDXC|MMC'))
    }
}

# TelmiDiskIO + TelmiFmifs : definis dans telmi-sd-common.ps1 (dot-source plus haut)

function Dismount-DiskVolumes([int]$num) {
    Get-Partition -DiskNumber $num -EA SilentlyContinue | ForEach-Object {
        if ($_.DriveLetter) {
            $ch = [char]$_.DriveLetter
            Write-Host ("  lock/dismount {0}:" -f $ch)
            try { [TelmiDiskIO]::LockAndDismountLetter($ch) } catch {}
            try { mountvol ("{0}:" -f $ch) /D 2>$null } catch {}
        }
    }
    Start-Sleep -Milliseconds 300
}

# Verrouille tous les volumes et GARDE les handles ouverts (empeche Windows de remonter mid-write)
function Lock-DiskVolumesPersistent([int]$num) {
    $handles = New-Object System.Collections.Generic.List[IntPtr]
    Get-Partition -DiskNumber $num -EA SilentlyContinue | ForEach-Object {
        if ($_.DriveLetter) {
            $ch = [char]$_.DriveLetter
            Write-Host ("  verrou persistant {0}: (garde ouvert)" -f $ch)
            $h = [TelmiDiskIO]::LockVolumeLetter($ch)
            if ($h -ne [TelmiDiskIO]::INVALID) {
                $handles.Add($h)
            } else {
                Write-Host ("  WARN: impossible de verrouiller {0}:" -f $ch) -ForegroundColor Yellow
            }
            try { mountvol ("{0}:" -f $ch) /D 2>$null } catch {}
        }
    }
    return $handles
}

function Unlock-DiskVolumesPersistent($handles) {
    if (-not $handles) { return }
    foreach ($h in $handles) {
        try { [void][TelmiDiskIO]::CloseHandle($h) } catch {}
    }
}

function Set-TelmiAutomount([bool]$enable) {
    if ($enable) {
        Write-Host '  automount ON'
        mountvol /E | Out-Null
    } else {
        Write-Host '  automount OFF (evite remount pendant flash)'
        mountvol /N | Out-Null
    }
}

# Efface TOUTES les partitions (comme "supprimer le volume" en Gestion des disques).
# Sans ca, Windows remonte BOOT/root/TELMI pendant le dd -> Win32=5.
function Clear-TelmiDisk([int]$num) {
    Write-Host ("==> Nettoyage complet du disque {0} (toutes partitions)..." -f $num)
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
        Write-Host ("  Clear-Disk: {0}  -  essai diskpart clean..." -f $_.Exception.Message)
    }
    if (-not $ok) {
        $out = @"
select disk $num
online disk
attributes disk clear readonly
clean
"@ | diskpart 2>&1 | Out-String
        if ($out -match 'error|erreur|failed') {
            Write-Host $out
            throw "diskpart clean a echoue sur disk $num"
        }
        Write-Host '  diskpart clean OK'
    }
    Start-Sleep -Seconds 1
    'rescan' | diskpart | Out-Null
    Start-Sleep -Milliseconds 500
}

function Set-TelmiDiskOffline([int]$num, [bool]$offline) {
    if ($offline) {
        Write-Host ("  offline disk {0}" -f $num)
        @"
select disk $num
offline disk
"@ | diskpart | Out-Null
        try { Set-Disk -Number $num -IsOffline $true -EA SilentlyContinue } catch {}
    } else {
        Write-Host ("  online disk {0}" -f $num)
        @"
select disk $num
online disk
attributes disk clear readonly
"@ | diskpart | Out-Null
        try { Set-Disk -Number $num -IsOffline $false -EA SilentlyContinue } catch {}
        try { Set-Disk -Number $num -IsReadOnly $false -EA SilentlyContinue } catch {}
    }
    Start-Sleep -Milliseconds 800
}

function Test-DiskIsOffline([int]$num) {
    try {
        $d = Get-Disk -Number $num -EA Stop
        return [bool]$d.IsOffline
    } catch { return $false }
}

function Open-PhysicalDriveHandle([int]$num) {
    $path = "\\.\PhysicalDrive$num"
    # Pas de WRITE_THROUGH : certains lecteurs USB renvoient ACCESS_DENIED (5) apres quelques Mo
    $h = [TelmiDiskIO]::CreateFile(
        $path,
        [TelmiDiskIO]::GENERIC_READ -bor [TelmiDiskIO]::GENERIC_WRITE,
        [TelmiDiskIO]::FILE_SHARE_READ -bor [TelmiDiskIO]::FILE_SHARE_WRITE,
        [IntPtr]::Zero,
        [TelmiDiskIO]::OPEN_EXISTING,
        0,
        [IntPtr]::Zero)
    if ($h -eq [TelmiDiskIO]::INVALID) {
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw ("CreateFile $path echoue (Win32=$err). Volume encore monte / Explorateur ouvert ?")
    }
    return $h
}

# CRC32 IEEE (GPT EFI)  -  ne jamais ecrire 0xFFFFFFFF nu (PS = Int32 -1)
function Get-Crc32([byte[]]$data) {
    $table = New-Object uint32[] 256
    $poly = [Convert]::ToUInt32('EDB88320', 16)
    $mask = [uint32]::MaxValue
    for ($i = 0; $i -lt 256; $i++) {
        [uint32]$c = [uint32]$i
        for ($k = 0; $k -lt 8; $k++) {
            if (($c -band 1) -ne 0) { $c = $poly -bxor ($c -shr 1) }
            else { $c = $c -shr 1 }
            $c = [uint32]($c -band $mask)
        }
        $table[$i] = $c
    }
    [uint32]$crc = $mask
    foreach ($b in $data) {
        $idx = [int](($crc -bxor [uint32]$b) -band 0xFF)
        $crc = $table[$idx] -bxor ($crc -shr 8)
        $crc = [uint32]($crc -band $mask)
    }
    return [uint32](($crc -bxor $mask) -band $mask)
}

function Get-GptHeaderCrc([byte[]]$hdr) {
    # UEFI : CRC uniquement sur HeaderSize octets (souvent 92), CRC field = 0
    $hdrSize = [int][BitConverter]::ToUInt32($hdr, 12)
    if ($hdrSize -lt 92 -or $hdrSize -gt 512) { $hdrSize = 92 }
    $slice = New-Object byte[] $hdrSize
    [Array]::Copy($hdr, 0, $slice, 0, $hdrSize)
    [Array]::Clear($slice, 16, 4)
    return (Get-Crc32 $slice)
}

function Repair-GptAlternate([int]$diskNum, [int64]$diskBytes) {
    # Relocalise le GPT secondaire en fin de disque (equiv. sgdisk -e)
    $sectorSize = 512L
    $lastLba = [int64]($diskBytes / $sectorSize) - 1L
    if ($lastLba -lt 100) { throw 'Disque trop petit pour GPT' }

    $h = Open-PhysicalDriveHandle -num $diskNum
    try {
        $mbr = New-Object byte[] 512
        $np = 0L
        [void][TelmiDiskIO]::SetFilePointerEx($h, 0L, [ref]$np, 0)
        $br = 0
        if (-not [TelmiDiskIO]::ReadFile($h, $mbr, 512, [ref]$br, [IntPtr]::Zero) -or $br -ne 512) {
            throw 'Lecture MBR incomplete'
        }
        if ($mbr[510] -eq 0x55 -and $mbr[511] -eq 0xAA) {
            # MBR : taille 32-bit. Eviter 0xFFFFFFFF (PS = Int32 -1 -> cast UInt64 impossible)
            if ($lastLba -gt 4294967295L) { $partSize = [uint32]::MaxValue }
            else { $partSize = [uint32]$lastLba }
            [BitConverter]::GetBytes([uint32]1).CopyTo($mbr, 454)
            [BitConverter]::GetBytes($partSize).CopyTo($mbr, 458)
            [void][TelmiDiskIO]::SetFilePointerEx($h, 0L, [ref]$np, 0)
            $bw = 0
            if (-not [TelmiDiskIO]::WriteFile($h, $mbr, 512, [ref]$bw, [IntPtr]::Zero)) {
                throw ("Ecriture MBR Win32=" + [Runtime.InteropServices.Marshal]::GetLastWin32Error())
            }
        }

        $hdr = New-Object byte[] 512
        [void][TelmiDiskIO]::SetFilePointerEx($h, $sectorSize, [ref]$np, 0)
        if (-not [TelmiDiskIO]::ReadFile($h, $hdr, 512, [ref]$br, [IntPtr]::Zero) -or $br -ne 512) {
            throw 'Lecture GPT primaire incomplete'
        }
        $sig = [Text.Encoding]::ASCII.GetString($hdr, 0, 8)
        if ($sig -ne 'EFI PART') { throw "Pas de GPT primaire ($sig)" }

        $entryStart = [BitConverter]::ToInt64($hdr, 72)
        $numEntries = [BitConverter]::ToUInt32($hdr, 80)
        $entrySize = [BitConverter]::ToUInt32($hdr, 84)
        if ($entrySize -eq 0) { $entrySize = 128 }
        if ($numEntries -eq 0) { $numEntries = 128 }
        $entriesBytes = [int]($numEntries * $entrySize)
        $entries = New-Object byte[] $entriesBytes
        [void][TelmiDiskIO]::SetFilePointerEx($h, ($entryStart * $sectorSize), [ref]$np, 0)
        if (-not [TelmiDiskIO]::ReadFile($h, $entries, [uint32]$entriesBytes, [ref]$br, [IntPtr]::Zero) -or $br -lt $entriesBytes) {
            throw 'Lecture table partitions GPT incomplete'
        }

        $firstUsable = [BitConverter]::ToInt64($hdr, 40)
        $entrySectors = [int64][Math]::Ceiling($entriesBytes / $sectorSize)
        $altEntryLba = $lastLba - $entrySectors
        $altHeaderLba = $lastLba
        $lastUsable = $altEntryLba - 1L

        $hdrNew = [byte[]]$hdr.Clone()
        [BitConverter]::GetBytes([int64]$altHeaderLba).CopyTo($hdrNew, 32)
        [BitConverter]::GetBytes([int64]$firstUsable).CopyTo($hdrNew, 40)
        [BitConverter]::GetBytes([int64]$lastUsable).CopyTo($hdrNew, 48)
        $entCrc = Get-Crc32 $entries
        [BitConverter]::GetBytes([uint32]$entCrc).CopyTo($hdrNew, 88)
        $hdrCrc = Get-GptHeaderCrc $hdrNew
        [BitConverter]::GetBytes([uint32]$hdrCrc).CopyTo($hdrNew, 16)

        [void][TelmiDiskIO]::SetFilePointerEx($h, $sectorSize, [ref]$np, 0)
        $bw = 0
        if (-not [TelmiDiskIO]::WriteFile($h, $hdrNew, 512, [ref]$bw, [IntPtr]::Zero)) {
            throw ("Ecriture GPT primaire Win32=" + [Runtime.InteropServices.Marshal]::GetLastWin32Error())
        }

        $hdrAlt = [byte[]]$hdrNew.Clone()
        [BitConverter]::GetBytes([int64]$altHeaderLba).CopyTo($hdrAlt, 24)
        [BitConverter]::GetBytes([int64]1).CopyTo($hdrAlt, 32)
        [BitConverter]::GetBytes([int64]$altEntryLba).CopyTo($hdrAlt, 72)
        [BitConverter]::GetBytes([uint32]$entCrc).CopyTo($hdrAlt, 88)
        $hdrAltCrc = Get-GptHeaderCrc $hdrAlt
        [BitConverter]::GetBytes([uint32]$hdrAltCrc).CopyTo($hdrAlt, 16)

        [void][TelmiDiskIO]::SetFilePointerEx($h, ($altEntryLba * $sectorSize), [ref]$np, 0)
        if (-not [TelmiDiskIO]::WriteFile($h, $entries, [uint32]$entriesBytes, [ref]$bw, [IntPtr]::Zero)) {
            throw ("Ecriture table GPT secondaire Win32=" + [Runtime.InteropServices.Marshal]::GetLastWin32Error())
        }
        [void][TelmiDiskIO]::SetFilePointerEx($h, ($altHeaderLba * $sectorSize), [ref]$np, 0)
        if (-not [TelmiDiskIO]::WriteFile($h, $hdrAlt, 512, [ref]$bw, [IntPtr]::Zero)) {
            throw ("Ecriture GPT secondaire Win32=" + [Runtime.InteropServices.Marshal]::GetLastWin32Error())
        }
        [void][TelmiDiskIO]::FlushFileBuffers($h)
        Write-Host ("  GPT secondaire -> LBA {0} (disque {1} secteurs)" -f $altHeaderLba, ($lastLba + 1))
    } finally {
        [void][TelmiDiskIO]::CloseHandle($h)
    }
}

function Write-ImageToPhysicalDrive([string]$imgPath, [int]$diskNum, [int64]$diskBytes) {
    $imgInfo = Get-Item $imgPath
    if ($imgInfo.Length -gt $diskBytes) {
        throw ("Image ({0}) plus grande que le disque ({1})" -f (Format-SizeGB $imgInfo.Length), (Format-SizeGB $diskBytes))
    }
    Write-Host ("==> Ecriture {0} -> PhysicalDrive{1} ..." -f $imgInfo.Name, $diskNum)

    [int]$bufSize = 1MB
    $buf = New-Object byte[] $bufSize
    $src = [System.IO.File]::OpenRead($imgPath)
    $h = Open-PhysicalDriveHandle -num $diskNum
    try {
        [int64]$written = 0L
        [int64]$total = $imgInfo.Length
        $lastPct = -1
        $np = 0L
        [void][TelmiDiskIO]::SetFilePointerEx($h, 0L, [ref]$np, 0)

        while ($written -lt $total) {
            $remaining = $total - $written
            [int]$toRead = if ($remaining -lt $bufSize) { [int]$remaining } else { $bufSize }
            $n = $src.Read($buf, 0, $toRead)
            if ($n -le 0) { break }

            $attempt = 0
            while ($true) {
                $bw = 0
                $ok = [TelmiDiskIO]::WriteFile($h, $buf, [uint32]$n, [ref]$bw, [IntPtr]::Zero)
                if ($ok) { break }

                $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                $attempt++
                # 5=ACCESS_DENIED, 21=NOT_READY, 15=NO_MEDIA
                if ($attempt -gt 5 -or ($err -ne 5 -and $err -ne 21 -and $err -ne 15)) {
                    $hint = switch ($err) {
                        5 { 'ACCESS_DENIED (volume remonte / antivirus / Explorateur)' }
                        21 { 'NOT_READY (lecteur SD)' }
                        15 { 'NO_MEDIA' }
                        default { "Win32=$err" }
                    }
                    throw ("WriteFile echoue a offset {0} ({1}). Fermez Explorateur sur la SD et reessayez." -f $written, $hint)
                }
                Write-Host ("  retry WriteFile offset={0} err={1} (tentative {2})..." -f $written, $err, $attempt) -ForegroundColor Yellow
                try { [void][TelmiDiskIO]::CloseHandle($h) } catch {}
                Start-Sleep -Milliseconds 700
                # Si Windows a remonte : re-verrouiller lettres encore presentes
                Get-Partition -DiskNumber $diskNum -EA SilentlyContinue | ForEach-Object {
                    if ($_.DriveLetter) {
                        try { [void][TelmiDiskIO]::LockAndDismountLetter([char]$_.DriveLetter) } catch {}
                        try { mountvol ("{0}:" -f $_.DriveLetter) /D 2>$null } catch {}
                    }
                }
                $h = Open-PhysicalDriveHandle -num $diskNum
                [void][TelmiDiskIO]::SetFilePointerEx($h, $written, [ref]$np, 0)
            }
            $written += $n
            $pct = [int](($written * 100L) / $total)
            if ($pct -ne $lastPct -and ($pct % 5 -eq 0)) {
                Write-Host ("  {0}% ({1:N1} / {2:N1} Mo)" -f $pct, ($written / 1MB), ($total / 1MB))
                $lastPct = $pct
            }
        }
        [void][TelmiDiskIO]::FlushFileBuffers($h)
        Write-Host '  Ecriture image OK'
    } finally {
        if ($src) { $src.Close() }
        if ($h -and $h -ne [TelmiDiskIO]::INVALID) {
            try { [void][TelmiDiskIO]::CloseHandle($h) } catch {}
        }
    }
}

function Expand-TelmiPartition([int]$diskNum) {
    Write-Host '==> Expand partition TELMI (reste du disque)...'
    Update-Disk -Number $diskNum -EA SilentlyContinue
    Start-Sleep -Seconds 1

    # Supprime p3+ (garde p1 BOOT, p2 root)
    Get-Partition -DiskNumber $diskNum -EA SilentlyContinue | Where-Object { $_.PartitionNumber -ge 3 } | ForEach-Object {
        $pn = $_.PartitionNumber
        $dl = $_.DriveLetter
        Write-Host ("  supprime partition {0}" -f $pn)
        try {
            if ($dl) { mountvol ("{0}:" -f $dl) /D 2>$null }
            Remove-Partition -DiskNumber $diskNum -PartitionNumber $pn -Confirm:$false
        } catch {
            Write-Host ("  WARN remove p{0}: {1}" -f $pn, $_.Exception.Message)
        }
    }
    Start-Sleep -Seconds 1
    'rescan' | diskpart | Out-Null
    Start-Sleep -Seconds 1

    $parts = @(Get-Partition -DiskNumber $diskNum | Sort-Object PartitionNumber)
    $p2 = $parts | Where-Object { $_.PartitionNumber -eq 2 } | Select-Object -First 1
    if (-not $p2) { throw 'Partition root (p2) introuvable - image incomplete ?' }

    Write-Host '  creation TELMI (espace libre max)...'
    try {
        $newPart = New-Partition -DiskNumber $diskNum -UseMaximumSize -AssignDriveLetter
    } catch {
        $disk = Get-Disk -Number $diskNum
        $telmiOffset = [int64]$p2.Offset + [int64]$p2.Size
        $align = 1MB
        if (($telmiOffset % $align) -ne 0) {
            $telmiOffset = [int64]([Math]::Ceiling($telmiOffset / $align) * $align)
        }
        $usable = [int64]$disk.Size - 34L * 512L
        $telmiSize = $usable - $telmiOffset
        if ($telmiSize -lt 50MB) { throw ("Espace TELMI insuffisant ({0} octets)" -f $telmiSize) }
        Write-Host ("  fallback offset={0:N0} taille={1}" -f $telmiOffset, (Format-SizeGB $telmiSize))
        $newPart = New-Partition -DiskNumber $diskNum -Offset $telmiOffset -Size $telmiSize -AssignDriveLetter
    }
    $letter = $newPart.DriveLetter
    if (-not $letter) {
        $newPart = Get-Partition -DiskNumber $diskNum -PartitionNumber $newPart.PartitionNumber
        $letter = $newPart.DriveLetter
    }
    if (-not $letter) {
        Add-PartitionAccessPath -DiskNumber $diskNum -PartitionNumber $newPart.PartitionNumber -AssignDriveLetter
        $letter = (Get-Partition -DiskNumber $diskNum -PartitionNumber $newPart.PartitionNumber).DriveLetter
    }
    if (-not $letter) { throw 'Impossible d assigner une lettre a TELMI' }

    $drive = '{0}:' -f $letter
    $volSize = [int64](Get-Partition -DiskNumber $diskNum -PartitionNumber $newPart.PartitionNumber).Size
    Write-Host ("  Format FAT32 label=TELMI sur {0} ({1}) ..." -f $drive, (Format-SizeGB $volSize))
    if (-not (Format-TelmiFat32 -DriveLetter $letter -SizeBytes $volSize)) {
        throw ("Format FAT32 echoue sur {0}. Fermez l Explorateur / antivirus sur ce volume et reessayez Expand-Telmi-SD.bat." -f $drive)
    }

    Seed-TelmiContent -DriveRoot $drive
    try { Set-Volume -DriveLetter $letter -NewFileSystemLabel 'TELMI' -EA SilentlyContinue } catch {}
    Write-Host ("  TELMI pret sur {0}" -f $drive)
}

function Format-TelmiFat32([char]$DriveLetter, [int64]$SizeBytes) {
    $drive = '{0}:' -f $DriveLetter
    $root = '{0}:\' -f $DriveLetter
    $limit32 = 32L * 1024L * 1024L * 1024L

    # <= 32 Go : Format-Volume suffit en general
    if ($SizeBytes -le $limit32) {
        try {
            Format-Volume -DriveLetter $DriveLetter -FileSystem FAT32 -NewFileSystemLabel 'TELMI' -Force -Confirm:$false | Out-Null
            $v = Get-Volume -DriveLetter $DriveLetter -EA SilentlyContinue
            if ($v -and $v.FileSystem -eq 'FAT32') {
                Write-Host '  Format-Volume FAT32 OK'
                return $true
            }
        } catch {
            Write-Host ("  Format-Volume: {0}" -f $_.Exception.Message)
        }
    } else {
        Write-Host '  Volume > 32 Go : FormatEx (fmifs) pour FAT32...'
    }

    # FormatEx : contourne la limite artificielle Windows (comme Rufus / fat32format)
    try { [TelmiDiskIO]::LockAndDismountLetter($DriveLetter) } catch {}
    Start-Sleep -Milliseconds 400

    # Clusters : 0=auto, puis 32K / 64K pour gros volumes
    $clusters = @(0, 32768, 65536)
    $medias = @([TelmiFmifs]::FmMediaRemovable, [TelmiFmifs]::FmMediaFixed)
    foreach ($media in $medias) {
        foreach ($cs in $clusters) {
            Write-Host ("  FormatEx media={0} cluster={1}..." -f $media, $cs)
            try {
                $ok = [TelmiFmifs]::TryFormatFat32($root, 'TELMI', [int]$media, [int]$cs)
                if ($ok) {
                    Start-Sleep -Seconds 1
                    $v = Get-Volume -DriveLetter $DriveLetter -EA SilentlyContinue
                    if ($v -and $v.FileSystem -eq 'FAT32') {
                        Write-Host '  FormatEx FAT32 OK'
                        return $true
                    }
                    # parfois le FS n est pas encore visible
                    if ($ok) {
                        Write-Host '  FormatEx signale OK'
                        return $true
                    }
                }
            } catch {
                Write-Host ("  FormatEx erreur: {0}" -f $_.Exception.Message)
            }
        }
    }

    # Secours : fat32format.exe dans scripts\tools\ (ridgecrop) si present
    $ff = Join-Path $ScriptDir 'tools\fat32format.exe'
    if (Test-Path $ff) {
        Write-Host ("  Essai {0} ..." -f $ff)
        $p = Start-Process -FilePath $ff -ArgumentList @('-y', $drive) -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -eq 0) {
            $v = Get-Volume -DriveLetter $DriveLetter -EA SilentlyContinue
            if ($v -and $v.FileSystem -eq 'FAT32') {
                Write-Host '  fat32format OK'
                return $true
            }
        }
    }

    return $false
}

function Seed-TelmiContent([string]$DriveRoot) {
    Seed-TelmiContentTree -DriveRoot $DriveRoot -ContentDir $ContentDir -TelmiR36 $TelmiR36
}

# --- main ---
Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' TelmiOS flash SD (Windows natif, sans WSL)' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan

$img = $null
if ($Mode -in @('from-image', 'os-only')) {
    $img = Get-LatestImage
    if (-not $img) { throw 'Aucune image telmi-r36-*.img (LATEST.txt)' }
    Write-Host (" Image : {0}" -f $img)
}

$disks = @(Get-RemovableDisks)
if ($disks.Count -eq 0) {
    Write-Host 'Aucun disque USB/SD amovible (>= 3 Go).' -ForegroundColor Red
    Get-Disk | Format-Table Number, FriendlyName, BusType, @{N='Size';E={Format-SizeGB $_.Size}} -AutoSize
    exit 1
}

if ($DiskNumber -ge 0) {
    $disk = Get-Disk -Number $DiskNumber -EA Stop
} else {
    Write-Host ''
    Write-Host ' Disques amovibles :'
    $map = @{}
    $i = 1
    foreach ($d in $disks) {
        Write-Host ("  [{0}] PhysicalDrive{1}  {2}  {3}" -f $i, $d.Number, (Format-SizeGB $d.Size), $d.FriendlyName)
        $map[$i] = $d
        $i++
    }
    Write-Host ''
    $sel = (Read-Host 'Numero dans la liste (ou Q)').Trim()
    if ($sel -eq 'Q' -or $sel -eq 'q') { Write-Host 'Annule.'; exit 0 }
    $n = 0
    if (-not [int]::TryParse($sel, [ref]$n) -or -not $map.ContainsKey($n)) { throw 'Choix invalide' }
    $disk = $map[$n]
}

$diskNum = [int]$disk.Number
$phys = "\\.\PhysicalDrive$diskNum"
Write-Host ''
Write-Host (" Cible : PhysicalDrive{0} ({1}) - {2}" -f $diskNum, (Format-SizeGB $disk.Size), $disk.FriendlyName) -ForegroundColor Yellow
Write-Host (" Mode  : {0}" -f $Mode)
Write-Host ' ATTENTION : le contenu du disque sera modifie.' -ForegroundColor Red

if (-not $Yes) {
    $c = Read-Host 'Tapez FLASH pour confirmer'
    if ($c -ne 'FLASH') { Write-Host 'Annule.'; exit 0 }
}

# Securite basique
if ($disk.IsBoot -or $disk.IsSystem) { throw 'Refus : disque systeme/boot Windows' }
if ($disk.Number -eq 0 -and -not $Yes) { throw 'Refus : PhysicalDrive0 (souvent le disque interne)' }

Write-Host '==> Preparation disque...'
Set-TelmiAutomount -enable $false
$script:FlashOk = $false
try {
    try { Set-Disk -Number $diskNum -IsReadOnly $false -EA SilentlyContinue } catch {}
    Set-TelmiDiskOffline -num $diskNum -offline $false

    if ($Mode -in @('from-image', 'os-only')) {
        Clear-TelmiDisk -num $diskNum
        Write-ImageToPhysicalDrive -imgPath $img -diskNum $diskNum -diskBytes ([int64]$disk.Size)
        Write-Host '==> Correction GPT (sgdisk -e equivalent)...'
        Repair-GptAlternate -diskNum $diskNum -diskBytes ([int64]$disk.Size)
    } else {
        # expand seul : ne pas clean  -  juste GPT + recreate TELMI
        Dismount-DiskVolumes -num $diskNum
        Write-Host '==> Correction GPT (sgdisk -e equivalent)...'
        Repair-GptAlternate -diskNum $diskNum -diskBytes ([int64]$disk.Size)
    }
    $script:FlashOk = $true
} finally {
    Set-TelmiDiskOffline -num $diskNum -offline $false
    Set-TelmiAutomount -enable $true
}

if (-not $script:FlashOk) {
    throw 'Flash/GPT interrompu  -  voir erreur ci-dessus.'
}

'rescan' | diskpart | Out-Null
Update-Disk -Number $diskNum -EA SilentlyContinue
Start-Sleep -Seconds 2
try { $null = Get-Partition -DiskNumber $diskNum } catch {}

if ($Mode -eq 'expand' -or $Mode -eq 'from-image') {
    Expand-TelmiPartition -diskNum $diskNum
} else {
    Write-Host ' Mode os-only : pas d expand p3 (contenu sur slot gauche via Prepare-Content-SD.bat)' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Green
if ($Mode -eq 'os-only') {
    Write-Host ' Flash OS OK (dual-SD)' -ForegroundColor Green
    Write-Host ' Ensuite : Prepare-Content-SD.bat (slot gauche) + Select-Telmi-REV.bat' -ForegroundColor Green
} else {
    Write-Host ' Flash/expand OK (sans WSL)' -ForegroundColor Green
    Write-Host ' Ensuite : Select-Telmi-REV.bat  (V20 ou V30 Panel4)' -ForegroundColor Green
}
Write-Host '============================================================' -ForegroundColor Green
