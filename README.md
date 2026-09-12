# Telmi Story Teller — R36S

Firmware **TelmiOS** pour console **R36S** (V20 clone et V30 Panel4).  
Version actuelle : **0.6.10** (`Telmi-R36/VERSION`).

| Chemin | Rôle |
|--------|------|
| `Telmi-R36/` | Portage, overlay, DTB, scripts build/flash, catalogue REV |
| `Telmi-story-teller-1.10.1/` | Sources Miyoo d’origine (headers / utils pour le build) |

L’image flashable `telmi-r36-0.6.10.img` n’est **pas** dans le dépôt (trop volumineuse) : publiez-la en **GitHub Release**.

## Flux dual-SD (recommandé)

```text
Slot DROIT (TF-OS)  : OS Telmi — flash une seule fois
Slot GAUCHE (TF2)   : contenu Stories/Music — Telmi Sync sur PC

1. Telmi-R36\Flash-Telmi-SD-OS-Only.bat
2. Telmi-R36\Prepare-Content-SD.bat     (carte gauche, label TELMI)
3. Telmi-R36\Select-Telmi-REV.bat       (volume BOOT carte droite)
4. Boot : contenu monté depuis le slot gauche sur /telmi
```

Retirer la SD **gauche** pour la synchroniser avec Telmi Sync (comme une Miyoo).

## Flux single-SD (legacy)

```text
1. Telmi-R36\Flash-Telmi-SD.bat         (flash + expand p3 TELMI)
2. Telmi-R36\Select-Telmi-REV.bat
3. Boot
```

## Scripts Windows

| Script | Rôle |
|--------|------|
| `Flash-Telmi-SD-OS-Only.bat` | OS slot droit, sans partition contenu |
| `Flash-Telmi-SD.bat` | Flash + expand p3 (single-SD) |
| `Prepare-Content-SD.bat` | Carte contenu slot gauche (FAT32 `TELMI`) |
| `Expand-Telmi-SD.bat` | Expand p3 seul |
| `Select-Telmi-REV.bat` | V20 / V30 Panel4 sur BOOT |
| `sd-diag\Enable-SD-Diag.bat` | Diagnostic MMC V30 (labo) |

## Build (WSL)

```bash
cd Telmi-R36
bash scripts/fetch-telmi-assets.sh
bash scripts/build-telmi-bins.sh unified storyTeller bootScreen
bash scripts/assemble-telmi-unified.sh
# OS-only dual-SD :
TELMI_OS_ONLY=1 bash scripts/assemble-telmi-unified.sh
```

Sortie : `Telmi-R36/output/telmi-r36-<VERSION>.img` + `LATEST.txt`

## Layout

**Slot droit (OS)** — GPT : BOOT | root ext4 | (p3 TELMI en single-SD seulement)  
**Slot gauche** — FAT32 label `TELMI` (Stories / Music / Saves / Games)

Catalogue REV : `Telmi-R36/boot/revs.json`  
Détails techniques : `Telmi-R36/docs/ADAPTATIONS-TELM-R36S.md`  
Historique : `Telmi-R36/CHANGELOG.md`

## Licence

Telmi story teller / TelmiOS : voir les licences des projets d’origine.
