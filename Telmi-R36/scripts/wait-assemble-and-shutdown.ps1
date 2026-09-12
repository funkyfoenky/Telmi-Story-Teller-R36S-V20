# Attend la fin de assemble-telmi-unified.sh puis eteint le PC.
param(
    [int]$PollSeconds = 20,
    [int]$ShutdownDelaySec = 120
)

$telmi = Split-Path -Parent $PSScriptRoot
$outImg = Join-Path $telmi 'output\telmi-r36-0.6.7.img'
$log = Join-Path $telmi 'output\assemble-shutdown.log'
$termLog = 'C:\Users\Utilisateur\.cursor\projects\c-Users-Utilisateur-Downloads-Tools-HelloWorld-R36S\terminals\410985.txt'

function Write-Log([string]$msg) {
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg"
    try { Add-Content -Path $log -Value $line -Encoding UTF8 } catch {}
}

Write-Log 'Watcher demarre'

while ($true) {
    $done = $false
    $failed = $false

    if (Test-Path $termLog) {
        $tail = Get-Content -Path $termLog -Tail 8 -ErrorAction SilentlyContinue
        $text = $tail -join "`n"
        if ($text -match 'exit_code:\s*0') {
            $done = $true
            Write-Log 'Terminal assemble : exit_code 0'
        } elseif ($text -match 'exit_code:\s*(\d+)') {
            $failed = $true
            Write-Log "Terminal assemble : exit_code $($Matches[1])"
        } elseif ($text -match 'OK|Sortie|manifest') {
            # assemble script prints success at end
        }
    }

    $wsl = @(Get-Process -Name 'wsl','wslhost' -ErrorAction SilentlyContinue)
    if (-not $done -and (Test-Path $outImg) -and $wsl.Count -eq 0) {
        $age = (Get-Date) - (Get-Item $outImg).LastWriteTime
        if ($age.TotalSeconds -gt 45) {
            $done = $true
            Write-Log 'Image presente, plus de WSL — assemble probablement fini'
        }
    }

    if ($done -or $failed) {
        $msg = if ($failed) { 'Assemblage Telmi termine (erreur possible)' } else { 'Telmi 0.6.7 assemble — extinction auto' }
        Write-Log "Arret PC dans ${ShutdownDelaySec}s : $msg"
        shutdown.exe /s /t $ShutdownDelaySec /c $msg
        exit 0
    }

    Start-Sleep -Seconds $PollSeconds
}
