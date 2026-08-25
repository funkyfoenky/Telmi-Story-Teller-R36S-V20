# Telmi-R36 — TelmiOS pour R36S (image unique multi-REV)

Portage de **Telmi story teller 1.10.1** vers **R36S** (V20 clone, V30 Panel4) en OS dédié.

## Flux dual-SD (recommandé depuis 0.6.0)

```text
Slot DROIT (TF-OS)  : OS Telmi — flash une seule fois
Slot GAUCHE (TF2)   : contenu Stories/Music — Telmi Sync sur PC

1. Flash-Telmi-SD-OS-Only.bat
2. Prepare-Content-SD.bat         (carte gauche, label TELMI)
3. Select-Telmi-REV.bat           (volume BOOT sur carte droite)
4. Boot : contenu monté depuis slot gauche sur /telmi
```

## Flux single-SD (legacy)

```text
1. Flash-Telmi-SD.bat
2. Select-Telmi-REV.bat
3. Boot
```

## Build image unique

```bash
bash scripts/build-telmi-bins.sh unified storyTeller bootScreen
bash scripts/assemble-telmi-unified.sh

# Image OS-only dual-SD (sans p3) :
TELMI_OS_ONLY=1 bash scripts/assemble-telmi-unified.sh
```

Sortie : `output/telmi-r36-<VERSION>.img` + `LATEST.txt`

## Scripts Windows

| Script | Rôle |
|--------|------|
| `Flash-Telmi-SD-OS-Only.bat` | OS slot droit, sans expand contenu |
| `Flash-Telmi-SD.bat` | Flash + expand p3 (single-SD) |
| `Prepare-Content-SD.bat` | Carte contenu slot gauche (FAT32 TELMI) |
| `Expand-Telmi-SD.bat` | Expand p3 seul |
| `Select-Telmi-REV.bat` | V20 / V30 Panel4 sur BOOT |
| `sd-diag/Enable-SD-Diag.bat` | Diagnostic slot gauche V30 |

## Layout cartes

**Slot droit (OS)** — GPT : p1 BOOT | p2 root | p3 TELMI (single-SD seulement)  
**Slot gauche** — 1 partition FAT32 label `TELMI`

Montage runtime : `overlay/opt/telmi/bin/telmi-mount-content.sh`

Voir `CHANGELOG.md` et `docs/ADAPTATIONS-TELM-R36S.md`.
