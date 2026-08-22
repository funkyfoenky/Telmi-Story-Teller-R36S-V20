# Copie la sonde audio sur le volume TELMI + flag d'activation.
# Si E:\AUDIO-PROBE est refuse, fallback : BOOT\TELMI-AUDIO-PROBE
# (le wrapper / runtime acceptent les deux).
$ErrorActionPreference = 'Stop'
$ProbeSrc = $PSScriptRoot

Write-Host ''
Write-Host ' Telmi V30 - Activer AUDIO PROBE'
Write-Host ' ================================'
Write-Host " Source: $ProbeSrc"
Write-Host ''
Write-Host ' Branche la SD. Volume TELMI = Stories/Saves (souvent E).'
Write-Host ' Volume BOOT = noyau (souvent D) - utilise en secours pour le flag.'
Write-Host ''
$letter = (Read-Host 'Lettre du volume TELMI (ex: E)').Trim().TrimEnd(':')
if ($letter -notmatch '^[A-Za-z]$') { throw 'Lettre invalide' }
$dstRoot = "${letter}:"
if (-not (Test-Path $dstRoot)) { throw "Lecteur $dstRoot introuvable" }

$dstProbe = Join-Path $dstRoot 'audio-probe'
New-Item -ItemType Directory -Force -Path $dstProbe | Out-Null
Copy-Item -Force (Join-Path $ProbeSrc 'run.sh') $dstProbe
Copy-Item -Force (Join-Path $ProbeSrc 'tone.wav') $dstProbe
Copy-Item -Force (Join-Path $ProbeSrc 'fbcolor') $dstProbe
if (Test-Path (Join-Path $ProbeSrc 'README.txt')) {
    Copy-Item -Force (Join-Path $ProbeSrc 'README.txt') $dstProbe
}
New-Item -ItemType Directory -Force -Path (Join-Path $dstRoot 'logs') | Out-Null
Write-Host " OK fichiers -> $dstProbe"

$flagTelmi = Join-Path $dstRoot 'AUDIO-PROBE'
$flagOk = $false
try {
    # Evite New-Item si ACL bizarre : ecriture directe
    [System.IO.File]::WriteAllText($flagTelmi, '')
    $flagOk = $true
    Write-Host " Flag OK -> $flagTelmi"
} catch {
    Write-Host " WARN: impossible d'ecrire $flagTelmi"
    Write-Host "  ($($_.Exception.Message))"
}

if (-not $flagOk) {
    Write-Host ''
    Write-Host ' Fallback : flag sur volume BOOT (TELMI-AUDIO-PROBE).'
    $bootLetter = (Read-Host 'Lettre du volume BOOT (ex: D)').Trim().TrimEnd(':')
    if ($bootLetter -notmatch '^[A-Za-z]$') { throw 'Lettre BOOT invalide' }
    $bootRoot = "${bootLetter}:"
    if (-not (Test-Path $bootRoot)) { throw "Lecteur $bootRoot introuvable" }
    $flagBoot = Join-Path $bootRoot 'TELMI-AUDIO-PROBE'
    try {
        [System.IO.File]::WriteAllText($flagBoot, '')
        Write-Host " Flag OK -> $flagBoot"
        $flagOk = $true
    } catch {
        Write-Host " ECHEC aussi sur BOOT: $($_.Exception.Message)"
        Write-Host ' Cree manuellement un fichier vide TELMI-AUDIO-PROBE a la racine de BOOT.'
        throw 'Impossible de creer le flag AUDIO-PROBE'
    }
}

Write-Host ''
Write-Host ' Pret. Ejecte la SD, boot la console.'
Write-Host ' Couleurs ecran = etapes. Puis lis TELMI:\logs\audio-probe.log'
Write-Host ''
