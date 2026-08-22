# Telmi-R36 — TelmiOS pour R36S (image unique multi-REV)

Portage de **[Telmi story teller 1.10.1](../Telmi-story-teller-1.10.1)** vers **R36S** (V20 clone, V30 Panel4, REVs futurs) en OS dédié.

## Flux produit (une seule image GitHub)

```text
1. Flasher  output/telmi-r36-<VERSION>.img   via Flash-Telmi-SD.bat
2. Choisir  Select-Telmi-REV.bat             (V20 ou V30 Panel4)
3. Boot console
```

Le sélecteur ne touche que la partition **BOOT** (FAT) : DTB actif + `TELMI-REV.txt`.  
Pas besoin de rebuilder ni de re-flasher pour changer de REV.

## Build image unique

```bash
# Bins unifies (quirks runtime via /boot/TELMI-REV.txt)
bash Telmi-R36/scripts/build-telmi-bins.sh unified storyTeller bootScreen

# Image ~2.2 Go (base V20 5.10 + DTB pack + bins)
bash Telmi-R36/scripts/assemble-telmi-unified.sh
```

Sortie : `Telmi-R36/output/telmi-r36-<VERSION>.img` + `LATEST.txt`  
Version : `Telmi-R36/VERSION`

Catalogue REV : `boot/revs.json` — DTB : `boot/dtb/v20.dtb`, `boot/dtb/v30-panel4.dtb`

## Flash sur une SD

```bat
Flash-Telmi-SD.bat
Select-Telmi-REV.bat
```

Ou Rufus (mode DD Image) puis `Select-Telmi-REV.bat`.

## Layout carte SD (slot droite TF-OS)

| Partition | Taille | Contenu |
|-----------|--------|---------|
| p1 BOOT | ~500 Mo | Noyau 5.10, `dtb/*`, `rf3536k3ka.dtb` (actif), `TELMI-REV.txt`, `revs.json` |
| p2 root | ~1,5 Go | TelmiOS (bins unifiés, res) |
| p3 TELMI | reste | Stories / Music / Games / Saves |

## Différences Miyoo → R36S

| Miyoo | R36S |
|-------|------|
| `SDL_AUDIODRIVER=mmiyoo` | `alsa` (Path SPK ou HP selon REV) |
| `SDL_VIDEODRIVER=mmiyoo` | `kmsdrm` + swrast |
| ARMv7 32-bit | AArch64 (RK3326) |

## Hors scope image unique

- Builds **ArkOS / noyau 4.4** (~8 Go) — labo uniquement
- DTB stock V30 4.4 (incompatibles avec le noyau 5.10)

Voir `profiles/README.md` et `CHANGELOG.md`.
