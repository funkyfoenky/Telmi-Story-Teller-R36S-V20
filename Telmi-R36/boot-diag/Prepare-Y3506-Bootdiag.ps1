# Prepare Y3506 bootdiag sur volume BOOT (DTB + REV + flag + DTBs manquants).
#Requires -Version 5
$ErrorActionPreference = 'Stop'

function Get-BootVolume {
    $vols = @(Get-Volume | Where-Object { $_.DriveLetter -and $_.FileSystemLabel -eq 'BOOT' })
    if ($vols.Count -eq 1) { return $vols[0] }
    if ($vols.Count -gt 1) {
        Write-Host ' Plusieurs volumes BOOT :'
        for ($i = 0; $i -lt $vols.Count; $i++) {
            Write-Host ("  [{0}] {1}:" -f ($i + 1), $vols[$i].DriveLetter)
        }
        $pick = (Read-Host 'Choix').Trim()
        $n = 0
        if (-not [int]::TryParse($pick, [ref]$n) -or $n -lt 1 -or $n -gt $vols.Count) {
            throw 'Choix invalide'
        }
        return $vols[$n - 1]
    }
    Write-Host 'Volume BOOT introuvable par label. Indiquez la lettre.'
    $letter = (Read-Host 'Lettre BOOT (ex: D)').Trim().TrimEnd(':')
    if ($letter -notmatch '^[A-Za-z]$') { throw 'Lettre invalide' }
    $v = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
    if (-not $v) { throw "Lecteur ${letter}: introuvable" }
    return $v
}

function Sync-DtbIfMissing([string]$bootRoot, [string]$repoDtbDir, [string]$name) {
    $dstDir = Join-Path $bootRoot 'dtb'
    $dst = Join-Path $dstDir $name
    if (Test-Path $dst) { return $false }
    $src = Join-Path $repoDtbDir $name
    if (-not (Test-Path $src)) { return $false }
    if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir | Out-Null }
    Copy-Item -Force $src $dst
    Write-Host ("  + copie dtb\{0} (manquant sur SD)" -f $name)
    return $true
}

Write-Host ''
Write-Host ' Telmi — Prepare Y3506 BOOTDIAG'
Write-Host ' ================================='
Write-Host ''

$boot = Get-BootVolume
$bootRoot = ("{0}:\" -f $boot.DriveLetter)
Write-Host (" BOOT = {0}" -f $bootRoot)

$repoRoot = Split-Path -Parent $PSScriptRoot
$repoDtb = Join-Path $repoRoot 'boot\dtb'

$imgVer = '?'
$verFile = Join-Path $bootRoot 'TELMI-VERSION.txt'
if (Test-Path $verFile) {
    $imgVer = (Get-Content -Raw $verFile).Trim()
}
Write-Host (" Image BOOT : {0}" -f $imgVer)

Write-Host ''
Write-Host ' Sync DTBs Y3506 si absents sur la SD...'
$names = @(
    'y3506-bootdiag.dtb',
    'y3506-t-panel4.dtb',
    'y3506-t-init.dtb',
    'y3506-t-timings.dtb',
    'y3506-v05b.dtb',
    'y3506-v05c.dtb',
    'y3506-v05d.dtb'
)
foreach ($n in $names) { Sync-DtbIfMissing $bootRoot $repoDtb $n | Out-Null }

$diag = Join-Path $bootRoot 'dtb\y3506-bootdiag.dtb'
if (-not (Test-Path $diag)) {
    $diagRepo = Join-Path $repoDtb 'y3506-bootdiag.dtb'
    if (Test-Path $diagRepo) {
        $dtbDir = Join-Path $bootRoot 'dtb'
        if (-not (Test-Path $dtbDir)) { New-Item -ItemType Directory -Path $dtbDir | Out-Null }
        Copy-Item -Force $diagRepo $diag
        Write-Host '  + y3506-bootdiag.dtb copie depuis le depot'
    } else {
        throw "y3506-bootdiag.dtb introuvable sur SD et dans $repoDtb"
    }
}

$active = Join-Path $bootRoot 'rf3536k3ka.dtb'
Copy-Item -Force $diag $active
Set-Content -Path (Join-Path $bootRoot 'TELMI-REV.txt') -Value 'y3506-bootdiag' -NoNewline -Encoding ascii
Set-Content -Path (Join-Path $bootRoot 'TELMI-AUDIO-PATH.txt') -Value 'HP' -NoNewline -Encoding ascii

$flag = Join-Path $bootRoot 'TELMI-BOOT-DIAG'
[System.IO.File]::WriteAllText($flag, '')

# Nettoyer un ancien verdict pour ne pas confondre
foreach ($old in @('telmi-boot-diag-VERDICT.txt', 'telmi-boot-diag.log')) {
    $p = Join-Path $bootRoot $old
    if (Test-Path $p) { Remove-Item -Force $p }
}

Write-Host ''
Write-Host ' OK — configuration bootdiag :'
Write-Host '   rf3536k3ka.dtb  <= y3506-bootdiag.dtb (DSI off)'
Write-Host '   TELMI-REV.txt   = y3506-bootdiag'
Write-Host '   TELMI-AUDIO-PATH.txt = HP'
Write-Host '   TELMI-BOOT-DIAG = actif'
Write-Host ''

$needsInject = $false
if ($imgVer -match '^0\.6\.([0-6])$') {
    $needsInject = $true
}

if ($needsInject) {
    Write-Host ' ATTENTION — image <= 0.6.6 : le script telmi-boot-diag.sh'
    Write-Host ' n est probablement PAS dans le rootfs.'
    Write-Host ''
    Write-Host ' Option A (observation seule, sans log Windows) :'
    Write-Host '   Bootez quand meme. Laissez 30-40 s.'
    Write-Host '   Si la console RESTE allumee plus longtemps qu avec v05b'
    Write-Host '   (batterie puis OFF en ~15 s) -> Linux demarre sans MIPI.'
    Write-Host ''
    Write-Host ' Option B (logs automatiques sur BOOT) :'
    Write-Host '   1) Flasher image >= 0.6.7, OU'
    Write-Host '   2) WSL : bash scripts/inject-boot-diag-into-sd.sh /dev/sdX'
    Write-Host ''
} else {
    Write-Host ' Procedure (image >= 0.6.7) :'
    Write-Host '   1. Ejectez la SD, inserez dans la Y3506'
    Write-Host '   2. Boot — ecran peut rester noir / batterie U-Boot'
    Write-Host '   3. Attendez 30-40 s (extinction auto si Linux OK)'
    Write-Host '   4. Remettez la SD dans le PC, lisez BOOT :'
    Write-Host '        telmi-boot-diag-VERDICT.txt'
    Write-Host '        telmi-boot-diag.log'
    Write-Host ''
    Write-Host ' VERDICT present  -> Linux demarre ; probleme = panel/DTB ecran'
    Write-Host ' Aucun fichier     -> mort avant userspace (noyau/DTB/chargeur)'
    Write-Host ''
}

Write-Host ' Ejectez la SD puis bootez.'
Write-Host ''
