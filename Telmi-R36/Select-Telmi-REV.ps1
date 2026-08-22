# Select-Telmi-REV.ps1 — apres flash, configure la REV sur le volume BOOT (FAT).
# Aucun WSL / rootfs : copie DTB + TELMI-REV.txt + TELMI-AUDIO-PATH.txt
$ErrorActionPreference = 'Stop'

function Get-BootVolume {
    $vols = @(Get-Volume | Where-Object {
        $_.DriveLetter -and $_.FileSystemLabel -eq 'BOOT'
    })
    if ($vols.Count -eq 1) { return $vols[0] }
    if ($vols.Count -gt 1) {
        Write-Host ' Plusieurs volumes BOOT :'
        for ($i = 0; $i -lt $vols.Count; $i++) {
            Write-Host ("  [{0}] {1}:  {2}" -f ($i + 1), $vols[$i].DriveLetter, $vols[$i].FileSystem)
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

Write-Host ''
Write-Host ' TelmiOS - Selection REV (post-flash)'
Write-Host ' ===================================='
Write-Host ''

$boot = Get-BootVolume
$root = ("{0}:\" -f $boot.DriveLetter)
Write-Host (" BOOT = {0}" -f $root)

$revsPath = Join-Path $root 'revs.json'
if (-not (Test-Path $revsPath)) {
    throw "revs.json absent sur $root - flashez d abord l image unique (telmi-r36-*.img)"
}

$catalog = Get-Content -Raw -Path $revsPath | ConvertFrom-Json
if (-not $catalog.revs -or $catalog.revs.Count -eq 0) {
    throw 'revs.json invalide (pas de revs)'
}

Write-Host ''
Write-Host ' REVs disponibles :'
for ($i = 0; $i -lt $catalog.revs.Count; $i++) {
    $r = $catalog.revs[$i]
    $mark = ''
    if ($r.id -eq $catalog.default) { $mark = ' (defaut image)' }
    Write-Host ("  [{0}] {1} - {2}{3}" -f ($i + 1), $r.id, $r.label, $mark)
}
Write-Host ''
$sel = (Read-Host 'Numero de REV').Trim()
$idx = 0
if (-not [int]::TryParse($sel, [ref]$idx) -or $idx -lt 1 -or $idx -gt $catalog.revs.Count) {
    throw 'Choix invalide'
}
$rev = $catalog.revs[$idx - 1]

$dtbRel = [string]$rev.dtb
$dtbSrc = Join-Path $root ($dtbRel -replace '/', '\')
if (-not (Test-Path $dtbSrc)) {
    throw "DTB manquant : $dtbSrc"
}

$activeName = 'rf3536k3ka.dtb'
if ($catalog.active_dtb) { $activeName = [string]$catalog.active_dtb }
$activeDst = Join-Path $root $activeName

Write-Host ''
Write-Host (" Application REV={0}" -f $rev.id)
Copy-Item -Force $dtbSrc $activeDst
Set-Content -Path (Join-Path $root 'TELMI-REV.txt') -Value $rev.id -NoNewline -Encoding ascii
Set-Content -Path (Join-Path $root 'TELMI-PROFILE.txt') -Value $rev.id -NoNewline -Encoding ascii
$audio = 'SPK'
if ($rev.audio_path) { $audio = [string]$rev.audio_path }
Set-Content -Path (Join-Path $root 'TELMI-AUDIO-PATH.txt') -Value $audio -NoNewline -Encoding ascii

Write-Host ("  DTB    : {0} <- {1}" -f $activeName, $dtbRel)
Write-Host ("  REV    : {0}" -f $rev.id)
Write-Host ("  Audio  : {0}" -f $audio)
Write-Host ''
Write-Host ' OK. Ejectez la SD et bootez la console.'
Write-Host ''
