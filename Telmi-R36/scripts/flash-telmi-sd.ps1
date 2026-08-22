# Flash TelmiOS sur carte SD - selection interactive des disques amovibles
# Lancer via Flash-Telmi-SD.bat (admin)
#
# Modes :
#   [1] Image LATEST  - dd telmi-r36-v20-*.img + expand TELMI (recommandé)
#   [2] Expand        - apres Rufus : agrandit seulement TELMI
#   [3] Complet       - rootfs.tar + sync bins depuis LATEST
#
# Non-interactif (Telmi Sync CardMaker R36S) :
#   powershell -File flash-telmi-sd.ps1 -DriveLetter E -Mode from-image -Yes
#   powershell -File flash-telmi-sd.ps1 -DiskNumber 2 -Mode from-image -Yes
#
# Requis : WSL2, image .img (mode 1) ou rootfs.tar (mode 3)
# Les lecteurs USB/SD passent par usbipd (wsl --mount ne les supporte pas).

#Requires -RunAsAdministrator
param(
    [int]$DiskNumber = -1,
    [string]$DriveLetter = "",
    [ValidateSet("from-image", "expand", "full")]
    [string]$Mode = "from-image",
    [ValidateSet("v20", "v30")]
    [string]$Profile = "v20",
    [switch]$Yes,
    [string]$ProgressFile = ""
)

$ErrorActionPreference = "Stop"
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::UTF8

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$TelmiR36 = Split-Path -Parent $ScriptDir
$FlashSh = Join-Path $ScriptDir "flash-telmi-sd.sh"
$FindSh = Join-Path $ScriptDir "telmi-find-sd-device.sh"
$RootfsTar = Join-Path $TelmiR36 "output\rootfs.tar"
$OutputDir = Join-Path $TelmiR36 "output"
if ($Profile -eq "v30") {
    $LatestFile = Join-Path $OutputDir "LATEST-V30.txt"
    $VersionFile = Join-Path $TelmiR36 "profiles\v30\VERSION"
    $ImgPrefix = "telmi-r36-v30-"
} else {
    # Image unique multi-REV (telmi-r36-<VERSION>.img) ou legacy v20
    $LatestFile = Join-Path $OutputDir "LATEST.txt"
    $VersionFile = Join-Path $TelmiR36 "VERSION"
    if (-not (Test-Path $VersionFile)) {
        $VersionFile = Join-Path $TelmiR36 "profiles\v20\VERSION"
    }
    $ImgPrefix = "telmi-r36-"
}
$Version = "?"
if (Test-Path $VersionFile) {
    $Version = (Get-Content $VersionFile -Raw).Trim()
}

function Get-LatestTelmiImage {
    # Preferer LATEST* (image terminee) avant le fichier VERSION (peut etre en cours d'assemble)
    if (Test-Path $LatestFile) {
        $name = (Get-Content $LatestFile -Raw).Trim()
        if ($name) {
            $p = Join-Path $OutputDir $name
            if (Test-Path $p) { return $p }
        }
    }
    $byVersion = Join-Path $OutputDir ("{0}{1}.img" -f $ImgPrefix, $Version)
    if (Test-Path $byVersion) { return $byVersion }
    # Legacy V20 prefix si image unique absente
    if ($Profile -ne "v30") {
        $legacy = Join-Path $OutputDir ("telmi-r36-v20-{0}.img" -f $Version)
        if (Test-Path $legacy) { return $legacy }
    }
    $imgs = @(Get-ChildItem -Path $OutputDir -Filter ("{0}*.img" -f $ImgPrefix) -ErrorAction SilentlyContinue |
        Where-Object {
            if ($Profile -eq "v30") { return $true }
            # Exclure les anciennes images v30-* du flash unique
            $_.Name -notmatch 'telmi-r36-v30-'
        } |
        Sort-Object LastWriteTime -Descending)
    if ($imgs.Count -gt 0) { return $imgs[0].FullName }
    return $null
}

$LatestImg = Get-LatestTelmiImage
$LatestImgName = if ($LatestImg) { Split-Path -Leaf $LatestImg } else { "(aucune)" }

$script:AttachedBusId = $null
$script:MountedPhys = $null
$script:ProgressFile = $ProgressFile
$script:ProgressTotal = 8

function Write-TelmiProgress {
    param(
        [Parameter(Mandatory=$true)][int]$Current,
        [Parameter(Mandatory=$true)][string]$Key
    )
    if ([string]::IsNullOrWhiteSpace($script:ProgressFile)) { return }
    try {
        $line = "{0}|{1}|{2}" -f $Current, $script:ProgressTotal, $Key
        # Fichier court : une seule ligne (le poller lit la derniere)
        [System.IO.File]::WriteAllText($script:ProgressFile, $line)
    } catch {}
}

function Write-Title([string]$t) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " $t" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
}

function Convert-ToWslPath([string]$winPath) {
    $wslPath = $null
    try {
        $wslPath = & wsl -e wslpath -a $winPath 2>$null | Select-Object -First 1
    } catch {}
    if ($wslPath) { return [string]$wslPath }
    $driveLetter = $winPath.Substring(0, 1).ToLowerInvariant()
    $rest = $winPath.Substring(2) -replace "\\", "/"
    return "/mnt/$driveLetter$rest"
}

function Get-RemovableDisks {
    Get-Disk | Where-Object {
        $_.Size -ge 3GB -and
        $_.OperationalStatus -eq "Online" -and
        (
            $_.BusType -eq "USB" -or
            $_.BusType -eq "SD" -or
            $_.BusType -eq "MMC" -or
            (
                $_.IsBoot -eq $false -and
                $_.IsSystem -eq $false -and
                $_.BusType -ne "NVMe" -and
                $_.BusType -ne "SATA" -and
                $_.BusType -ne "RAID"
            )
        ) -and
        $_.IsBoot -ne $true -and
        $_.IsSystem -ne $true
    } | Sort-Object Number
}

function Format-SizeGB([long]$bytes) {
    return ("{0:N1} Go" -f ($bytes / 1GB))
}

# Execute une commande native sans faire planter Stop sur stderr (usbipd info, etc.)
function Invoke-Native {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(ValueFromRemainingArguments=$true)][string[]]$ArgumentList
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $out = & $FilePath @ArgumentList 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return [pscustomobject]@{
        ExitCode = $code
        Output = ($out -join "`n")
    }
}

function Get-UsbipdExe {
    $cmd = Get-Command usbipd -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $fallback = "C:\Program Files\usbipd-win\usbipd.exe"
    if (Test-Path $fallback) { return $fallback }
    return $null
}

function Get-UsbipdStorageDevices {
    param([string]$Usbipd)
    $listRes = Invoke-Native $Usbipd list
    $raw = $listRes.Output
    $devices = @()
    foreach ($line in ($raw -split "`r?`n")) {
        if ($line -match '^\s*(\d+-\d+)\s+(\S+)\s+(.+?)\s+(Not shared|Shared|Attached)') {
            $busId = $Matches[1]
            $vidPid = $Matches[2]
            $name = $Matches[3].Trim()
            $state = $Matches[4]

            if ($name -match '(?i)Keyboard|Mouse|Hub|HID|Bluetooth|Camera|Audio|Input|Entr.e|Controller|Ethernet|Network|Wi-?Fi|Headset|Microphone|Printer|Serial|Billboard|ST-Link|Debug') {
                continue
            }
            if ($name -notmatch '(?i)Mass Storage|stockage de masse|Card Reader|lecteur de cartes|USB Flash|Flash Drive|USB Disk|SCSI Disk') {
                continue
            }

            $devices += [pscustomobject]@{
                BusId = $busId
                VidPid = $vidPid
                Name = $name
                State = $state
            }
        }
    }
    return $devices
}

function Connect-DiskToWsl {
    param(
        [Parameter(Mandatory=$true)]$Disk,
        [Parameter(Mandatory=$true)][int64]$DiskBytes
    )

    $diskNum = $Disk.Number
    $phys = ("\\.\PHYSICALDRIVE{0}" -f $diskNum)
    $isUsb = ($Disk.BusType -eq "USB" -or $Disk.BusType -eq "SD" -or $Disk.BusType -eq "MMC")

    # --- Chemin USB : usbipd (wsl --mount ne marche PAS sur USB flash/SD) ---
    if ($isUsb) {
        Write-Host "==> Lecteur USB/SD detecte : utilisation de usbipd (pas wsl --mount)" -ForegroundColor Yellow
        $usbipd = Get-UsbipdExe
        if (-not $usbipd) {
            Write-Host "ERREUR : usbipd-win n'est pas installe." -ForegroundColor Red
            Write-Host "         Installez-le puis relancez :"
            Write-Host "         winget install dorssel.usbipd-win"
            exit 1
        }

        & wsl -e true 2>$null | Out-Null

        $candidates = @(Get-UsbipdStorageDevices -Usbipd $usbipd)
        if ($candidates.Count -eq 0) {
            Write-Host "ERREUR : aucun peripherique USB stockage dans 'usbipd list'." -ForegroundColor Red
            Invoke-Native $usbipd list | ForEach-Object { Write-Host $_.Output }
            Write-Host "Rebranchez la carte / le lecteur, puis relancez."
            exit 1
        }

        $chosen = $null
        if ($candidates.Count -eq 1) {
            $chosen = $candidates[0]
            Write-Host ("==> USB stockage : bus {0} ({1})" -f $chosen.BusId, $chosen.Name) -ForegroundColor Green
        } else {
            Write-Host ""
            Write-Host " Plusieurs USB stockage detectes - choisissez celui de la SD :"
            for ($i = 0; $i -lt $candidates.Count; $i++) {
                $c = $candidates[$i]
                Write-Host ("   [{0}] bus {1}  {2}  ({3})" -f ($i + 1), $c.BusId, $c.Name, $c.State)
            }
            $pick = Read-Host ("Choix 1-{0}" -f $candidates.Count)
            $pi = 0
            if (-not [int]::TryParse($pick, [ref]$pi) -or $pi -lt 1 -or $pi -gt $candidates.Count) {
                Write-Host "Choix invalide." -ForegroundColor Red
                exit 1
            }
            $chosen = $candidates[$pi - 1]
        }

        Write-Host ("==> usbipd bind/attach bus {0} ({1})..." -f $chosen.BusId, $chosen.Name) -ForegroundColor Yellow

        try {
            Get-Partition -DiskNumber $diskNum -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.DriveLetter) {
                    $dl = ("{0}:" -f $_.DriveLetter)
                    Write-Host ("    demonte {0}" -f $dl)
                    mountvol $dl /D 2>$null
                }
            }
        } catch {}

        # Detach eventuel puis bind + attach (stderr info ne doit pas etre fatal)
        [void](Invoke-Native $usbipd detach --busid $chosen.BusId)
        Start-Sleep -Milliseconds 300
        $bindRes = Invoke-Native $usbipd bind --busid $chosen.BusId
        Start-Sleep -Milliseconds 400
        $attachRes = Invoke-Native $usbipd attach --wsl --busid $chosen.BusId
        if ($attachRes.Output) { Write-Host $attachRes.Output }
        if ($attachRes.ExitCode -ne 0) {
            Write-Host "Echec usbipd attach (code $($attachRes.ExitCode))." -ForegroundColor Red
            Write-Host "Verifiez que WSL est demarre : wsl -e true" -ForegroundColor Red
            exit 1
        }
        $script:AttachedBusId = $chosen.BusId
        Write-Host "==> Attente apparition du disque dans WSL..." -ForegroundColor Yellow
        Start-Sleep -Seconds 3
        return
    }

    # --- Disque non-USB : wsl --mount --bare ---
    Write-Host ("==> Montage WSL : wsl --mount {0} --bare" -f $phys) -ForegroundColor Yellow
    try {
        Get-Partition -DiskNumber $diskNum -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.DriveLetter) {
                mountvol (("{0}:" -f $_.DriveLetter)) /D 2>$null
            }
        }
    } catch {}
    Set-Disk -Number $diskNum -IsOffline $true -ErrorAction Stop
    Start-Sleep -Seconds 1
    wsl --unmount $phys 2>$null | Out-Null
    $mountOut = & wsl --mount $phys --bare 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Set-Disk -Number $diskNum -IsOffline $false -ErrorAction SilentlyContinue
        Write-Host $mountOut -ForegroundColor Red
        Write-Host "Echec wsl --mount." -ForegroundColor Red
        exit 1
    }
    $script:MountedPhys = $phys
    Write-Host $mountOut
}

function Disconnect-DiskFromWsl {
    if ($script:AttachedBusId) {
        $usbipd = Get-UsbipdExe
        if ($usbipd) {
            Write-Host ("==> usbipd detach bus {0}..." -f $script:AttachedBusId) -ForegroundColor Yellow
            [void](Invoke-Native $usbipd detach --busid $script:AttachedBusId)
        }
        $script:AttachedBusId = $null
    }
    if ($script:MountedPhys) {
        Write-Host "==> wsl --unmount..." -ForegroundColor Yellow
        $prev = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        wsl --unmount $script:MountedPhys 2>$null | Out-Null
        $ErrorActionPreference = $prev
        $script:MountedPhys = $null
    }
}

Write-Title ("TelmiOS R36S - Flash SD  (v{0})" -f $Version)
Write-Host (" Dossier : {0}" -f $TelmiR36)
Write-Host (" Profil  : {0}" -f $Profile)
Write-Host (" Image   : {0}" -f $LatestImgName)
Write-Host ""

if (-not (Test-Path $FlashSh)) {
    Write-Host ("ERREUR : script manquant : {0}" -f $FlashSh) -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $FindSh)) {
    Write-Host ("ERREUR : script manquant : {0}" -f $FindSh) -ForegroundColor Red
    exit 1
}

# --- Mode non-interactif (Telmi Sync) ---
$FlashMode = "from-image"
$disk = $null
$diskNum = -1
$diskBytes = [int64]0

if ($Yes) {
    $FlashMode = $Mode
    if ($DiskNumber -ge 0) {
        $diskNum = $DiskNumber
    }
    elseif (-not [string]::IsNullOrWhiteSpace($DriveLetter)) {
        $letter = $DriveLetter.Trim().TrimEnd(':').Substring(0, 1).ToUpperInvariant()
        try {
            $part = Get-Partition -DriveLetter $letter -ErrorAction Stop
            $diskNum = [int]$part.DiskNumber
            Write-Host ("==> Lettre {0}: → PHYSICALDRIVE{1}" -f $letter, $diskNum) -ForegroundColor Green
        }
        catch {
            Write-Host ("ERREUR : impossible de résoudre le disque pour {0}:" -f $letter) -ForegroundColor Red
            Write-Host $_
            exit 1
        }
    }
    else {
        Write-Host "ERREUR : -Yes requiert -DiskNumber ou -DriveLetter" -ForegroundColor Red
        exit 1
    }

    try {
        $disk = Get-Disk -Number $diskNum -ErrorAction Stop
    }
    catch {
        Write-Host ("ERREUR : disque {0} introuvable" -f $diskNum) -ForegroundColor Red
        exit 1
    }
    $diskBytes = [int64]$disk.Size

    if ($disk.IsBoot -or $disk.IsSystem) {
        Write-Host "ERREUR : refus de flasher un disque systeme/boot" -ForegroundColor Red
        exit 1
    }
    if ($diskBytes -lt 3GB) {
        Write-Host "ERREUR : disque trop petit (< 3 Go)" -ForegroundColor Red
        exit 1
    }
}
else {
    Write-Host " Nouveautes incluses (image LATEST) :" -ForegroundColor DarkCyan
    Write-Host "   - Emulateurs : GB, GBC, GBA (mGBA), NES, MD, SNES, PSX (CHD ok)"
    Write-Host "   - Volume ALSA dans les cores libretro (VOL+/-)"
    Write-Host "   - Luminosite sysfs backlight R36S"
    Write-Host "   - Partition TELMI : Games/gb gbc gba nes md snes psx + Saves/"

    Write-Host ""
    Write-Host " Mode de flash :"
    Write-Host "   [1] Image LATEST - ecrit l'image TelmiOS + agrandit TELMI  (recommande)"
    Write-Host "   [2] Expand       - apres Rufus d'une .img : agrandit seulement TELMI"
    Write-Host "   [3] Complet      - rootfs.tar + sync bins LATEST (avance)"
    Write-Host ""
    $modeChoice = Read-Host "Choix (1/2/3) [1]"
    if ([string]::IsNullOrWhiteSpace($modeChoice)) { $modeChoice = "1" }

    switch ($modeChoice) {
        "2" { $FlashMode = "expand" }
        "3" { $FlashMode = "full" }
        default { $FlashMode = "from-image" }
    }
}

if ($FlashMode -eq "from-image") {
    if (-not $LatestImg) {
        Write-Host "ERREUR : aucune image telmi-r36-v20-*.img dans output\" -ForegroundColor Red
        Write-Host "         Lancez assemble / quick-update d'abord."
        exit 1
    }
}
elseif ($FlashMode -eq "full") {
    if (-not (Test-Path $RootfsTar)) {
        Write-Host "ERREUR : rootfs.tar manquant." -ForegroundColor Red
        Write-Host "         Lancez d'abord : bash Telmi-R36/scripts/build-telmi-rootfs.sh"
        exit 1
    }
}

if (-not $Yes) {
Write-Host ""
Write-Host " Recherche des peripheriques amovibles..." -ForegroundColor Yellow
$disks = @(Get-RemovableDisks)

if ($disks.Count -eq 0) {
    Write-Host ""
    Write-Host "Aucun disque USB/SD amovible trouve (>= 3 Go)." -ForegroundColor Red
    Write-Host "Inserez la carte, attendez qu'elle apparaisse, puis relancez."
    Write-Host ""
    Write-Host "Tous les disques :"
    Get-Disk | Format-Table Number, FriendlyName, BusType, @{N="Size";E={Format-SizeGB $_.Size}}, PartitionStyle, OperationalStatus -AutoSize
    exit 1
}

Write-Host ""
Write-Host " Disques amovibles :" -ForegroundColor Green
Write-Host (" {0,-4} {1,-10} {2,-8} {3,-28} {4}" -f "No", "Taille", "Bus", "Nom", "Partitions")
Write-Host (" {0,-4} {1,-10} {2,-8} {3,-28} {4}" -f "--", "------", "---", "---", "----------")

$indexMap = @{}
$i = 1
foreach ($d in $disks) {
    $parts = @()
    try {
        Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.DriveLetter) {
                $parts += ("{0}:" -f $_.DriveLetter)
            } else {
                $parts += "-"
            }
        }
    } catch {}
    $partStr = "(vide)"
    if ($parts.Count -gt 0) { $partStr = ($parts -join " ") }
    $name = $d.FriendlyName
    if ([string]::IsNullOrWhiteSpace($name)) { $name = ("Disque {0}" -f $d.Number) }
    $nameShort = $name
    if ($nameShort.Length -gt 28) { $nameShort = $nameShort.Substring(0, 28) }
    Write-Host (" {0,-4} {1,-10} {2,-8} {3,-28} {4}" -f $i, (Format-SizeGB $d.Size), $d.BusType, $nameShort, $partStr)
    $indexMap[$i] = $d
    $i++
}

Write-Host ""
$sel = Read-Host "Numero du disque a flasher (ou Q pour quitter)"
if ($sel -eq "Q" -or $sel -eq "q") {
    Write-Host "Annule."
    exit 0
}
$selNum = 0
if (-not [int]::TryParse($sel, [ref]$selNum) -or -not $indexMap.ContainsKey($selNum)) {
    Write-Host "Choix invalide." -ForegroundColor Red
    exit 1
}

$disk = $indexMap[$selNum]
$diskNum = $disk.Number
$diskBytes = [int64]$disk.Size

Write-Host ""
Write-Host " Vous avez choisi :" -ForegroundColor Yellow
Write-Host ("   PHYSICALDRIVE{0} - {1} - {2} - {3}" -f $diskNum, (Format-SizeGB $diskBytes), $disk.FriendlyName, $disk.BusType)
switch ($FlashMode) {
    "expand" {
        Write-Host "   Mode : EXPAND (TELMI seulement)"
    }
    "full" {
        Write-Host "   Mode : FLASH COMPLET (rootfs.tar + sync LATEST)"
    }
    default {
        Write-Host ("   Mode : IMAGE LATEST ({0})" -f $LatestImgName)
    }
}
Write-Host ""
Write-Host " ATTENTION : le contenu de ce disque sera ecrase." -ForegroundColor Red
$confirm = Read-Host "Tapez FLASH pour confirmer"
if ($confirm -ne "FLASH") {
    Write-Host "Annule."
    exit 0
}
} else {
    Write-Host ""
    Write-Host " Mode non-interactif (-Yes) :" -ForegroundColor Yellow
    Write-Host ("   PHYSICALDRIVE{0} - {1} - {2} - {3}" -f $diskNum, (Format-SizeGB $diskBytes), $disk.FriendlyName, $disk.BusType)
    Write-Host ("   Mode : {0}" -f $FlashMode)
    Write-Host " ATTENTION : le contenu de ce disque sera ecrase." -ForegroundColor Red
}

Write-TelmiProgress -Current 1 -Key "r36s-step-prepare"

Write-Host ""
try {
    Write-TelmiProgress -Current 2 -Key "r36s-step-attach"
    Connect-DiskToWsl -Disk $disk -DiskBytes $diskBytes

    $flashShWsl = Convert-ToWslPath $FlashSh
    $findShWsl = Convert-ToWslPath $FindSh

    Write-TelmiProgress -Current 3 -Key "r36s-step-detect"
    Write-Host ("==> Recherche du device dans WSL (taille = {0} octets)..." -f $diskBytes) -ForegroundColor Yellow

    $wslDev = $null
    for ($try = 1; $try -le 10; $try++) {
        $findOut = & wsl -u root -e bash $findShWsl $diskBytes 2>&1
        foreach ($line in @($findOut)) {
            $t = ([string]$line).Trim()
            if ($t.StartsWith("/dev/")) {
                $wslDev = $t
                break
            }
        }
        if ($wslDev) { break }
        Write-Host ("    tentative {0}/10..." -f $try)
        Start-Sleep -Seconds 1
    }

    if (-not $wslDev) {
        Write-Host "Device WSL introuvable. Sortie :" -ForegroundColor Red
        Write-Host ($findOut | Out-String)
        Write-Host ""
        Write-Host "Si usbipd a attache le USB mais lsblk est vide, le noyau WSL" -ForegroundColor Yellow
        Write-Host "n'a peut-etre pas le module USB mass-storage."
        & wsl -u root -e lsblk
        throw "Device introuvable"
    }

    Write-Host ("==> Device WSL : {0}" -f $wslDev) -ForegroundColor Green
    Write-Host "==> Lancement flash (peut prendre plusieurs minutes)..." -ForegroundColor Yellow
    Write-Host ""

    if ($FlashMode -eq "expand") {
        Write-TelmiProgress -Current 4 -Key "r36s-step-expand"
        $flashCmd = 'bash "' + $flashShWsl + '" "' + $wslDev + '" --yes --expand'
    }
    elseif ($FlashMode -eq "full") {
        Write-TelmiProgress -Current 4 -Key "r36s-step-write"
        $flashCmd = 'bash "' + $flashShWsl + '" "' + $wslDev + '" --yes'
    }
    else {
        Write-TelmiProgress -Current 4 -Key "r36s-step-write"
        $flashCmd = 'bash "' + $flashShWsl + '" "' + $wslDev + '" --yes --from-image'
    }
    # Pendant le flash long : etape 5 (expand/seed dans le script bash)
    Write-TelmiProgress -Current 5 -Key "r36s-step-expand"
    & wsl -u root -e bash -lc $flashCmd
    $flashExit = $LASTEXITCODE
    if ($flashExit -eq 0) {
        Write-TelmiProgress -Current 6 -Key "r36s-step-seed"
    }
}
catch {
    Write-Host ("Erreur : {0}" -f $_) -ForegroundColor Red
    $flashExit = 1
}
finally {
    Write-TelmiProgress -Current 7 -Key "r36s-step-cleanup"
    Write-Host ""
    Disconnect-DiskFromWsl
    try {
        Set-Disk -Number $diskNum -IsOffline $false -ErrorAction SilentlyContinue
    } catch {}
}

if ($flashExit -eq 0) {
    Write-TelmiProgress -Current 8 -Key "r36s-step-done"
    Write-Title "Flash termine avec succes"
    Write-Host " Ejectez proprement la SD, puis demarrez la R36S (slot droite TF-OS)." -ForegroundColor Green
    Write-Host " Partition TELMI : Stories / Music / Games/{gb,gbc,gba,nes,md,snes,psx}"
    Write-Host " BIOS PSX (si besoin) : copiez scph5501.bin dans Saves/"
    exit 0
} else {
    Write-Host ("Flash echoue (code {0})." -f $flashExit) -ForegroundColor Red
    exit $flashExit
}

