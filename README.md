# TelmiOS pour R36S

Firmware **TelmiOS** dédié à la console **R36S** (layout GPT : BOOT + rootfs ext4 + TELMI FAT32).

Version actuelle : **0.5.0** — image unique multi-REV (voir `Telmi-R36/VERSION`).

Ce dépôt contient :

| Chemin | Rôle |
|--------|------|
| `Telmi-R36/` | Portage, overlay, scripts build/flash, catalogue REV |
| `Telmi-story-teller-1.10.1/` | Sources Miyoo d'origine (headers / utils communs au build) |

## Flux utilisateur (une seule image)

```text
1. Flasher  Telmi-R36/output/telmi-r36-0.5.0.img   via Flash-Telmi-SD.bat
2. Choisir  Select-Telmi-REV.bat                   (V20 ou V30 Panel4)
3. Boot console
```

- Flash **100 % Windows** (pas de WSL) : `Flash-Telmi-SD.bat` → `scripts/flash-telmi-sd-win.ps1`
- Expand TELMI seul : `Expand-Telmi-SD.bat`
- Le sélecteur REV ne touche que la partition **BOOT** (DTB + `TELMI-REV.txt`)

## Prérequis build

- WSL2 (Ubuntu) + toolchain Buildroot aarch64
- Windows admin pour le flash SD natif

## Structure

```
Telmi-Story-Teller-R36S/
  Telmi-R36/
  Telmi-story-teller-1.10.1/   # sibling requis par le package Buildroot
```

## Build image unique

```bash
cd Telmi-R36

# Assets UI (si besoin)
bash scripts/fetch-telmi-assets.sh

# Bins unifiés (quirks runtime via /boot/TELMI-REV.txt)
bash scripts/build-telmi-bins.sh unified storyTeller bootScreen

# Image ~2.2 Go
bash scripts/assemble-telmi-unified.sh
```

Sortie : `Telmi-R36/output/telmi-r36-<VERSION>.img` + `LATEST.txt`

Catalogue REV : `Telmi-R36/boot/revs.json`  
DTB : `Telmi-R36/boot/dtb/v20.dtb`, `v30-panel4.dtb`

## Flash SD (Windows)

```bat
cd Telmi-R36
Flash-Telmi-SD.bat
Select-Telmi-REV.bat
```

Layout GPT : **BOOT** (~500 Mo) | **root** (~1,5 Go ext4) | **TELMI** (reste, FAT32 : Stories / Music / Games / Saves).

## Contenu utilisateur (partition TELMI)

- `Stories/`, `Music/`, `Games/{gb,gbc,gba,nes,md,snes,psx}/`
- `Saves/.parameters` — combo menu jeux (`gameUnlockCombo`), contrôles, etc.
- `config/controls.json` — mapping boutons par console

## Licence

Telmi story teller / TelmiOS : voir les licences des projets d'origine.
