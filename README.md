# TelmiOS pour R36S

Firmware **TelmiOS** dédié à la console **R36S** (layout GPT : BOOT + rootfs ext4 + TELMI FAT32).

Ce dossier contient :

| Chemin | Rôle |
|--------|------|
| `Telmi-R36/` | Portage, overlay, scripts build/flash, assets UI |
| `Telmi-story-teller-1.10.1/` | Sources Miyoo d’origine (headers / utils communs au build) |

Version image actuelle : voir `Telmi-R36/VERSION`.

## Prérequis

- WSL2 (Ubuntu) + toolchain Buildroot aarch64 (même base que le projet Hello World R36S)
- Windows pour le flash SD PowerShell (`scripts/flash-telmi-sd.ps1`)
- `fuse2fs` / outils dans `Telmi-R36/.tools` après un premier assemble complet

## Structure attendue

```
TelmiOS-R36S/
  Telmi-R36/
  Telmi-story-teller-1.10.1/   # sibling requis par le package Buildroot
```

## Build

```bash
cd Telmi-R36

# Assets UI (si besoin)
bash scripts/fetch-telmi-assets.sh

# Rootfs Buildroot
bash scripts/build-telmi-rootfs.sh

# Image SD versionnée
sudo bash scripts/assemble-telmi-v20.sh

# Ou mise à jour rapide des binaires Telmi seulement :
bash scripts/quick-update-telmi.sh
```

Image : `Telmi-R36/output/telmi-r36-v20-<VERSION>.img`  
`output/LATEST.txt` indique la version à flasher.

## Flash SD (Windows)

```powershell
# Depuis Telmi-R36
.\Flash-Telmi-SD.bat
# ou
powershell -ExecutionPolicy Bypass -File scripts\flash-telmi-sd.ps1 -DriveLetter E -Mode from-image -Yes
```

Layout GPT : **BOOT** (~500 Mo) | **root** (~1,5 Go ext4) | **TELMI** (reste, FAT32 : Stories / Music / Games / Saves).

## Contenu utilisateur (partition TELMI)

- `Stories/`, `Music/`, `Games/{gb,gbc,gba,nes,md,snes,psx}/`
- `Saves/.parameters` — combo menu jeux (`gameUnlockCombo`), contrôles, etc.
- `config/controls.json` — mapping boutons par console

## Licence

Telmi story teller / TelmiOS : voir les licences des projets d’origine.
