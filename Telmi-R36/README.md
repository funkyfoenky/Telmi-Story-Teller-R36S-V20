# Telmi-R36 — TelmiOS pour R36S (V20 clone)

Portage de **[Telmi story teller 1.10.1](../Telmi-story-teller-1.10.1)** (Miyoo Mini Plus) vers **R36S-V20** en OS dédié avec boot direct sur TelmiOS.

## Prérequis

- Image V20 qui boot déjà (`R36S-Clone_V20_2025-05-08.img` ou stock-light)
- WSL + Buildroot (même toolchain que Hello World)
- Assets Telmi (polices, PNG, configs) : `bash scripts/fetch-telmi-assets.sh`

## Build rapide

```bash
# 1. Assets UI (une fois)
bash Telmi-R36/scripts/fetch-telmi-assets.sh

# 2. Rootfs TelmiOS (Buildroot)
bash Telmi-R36/scripts/build-telmi-rootfs.sh

# 3. Incrementez la version si besoin (obligatoire si l'image existe deja)
#    echo 0.4.0 > Telmi-R36/VERSION

# 4. Image SD versionnee
sudo bash Telmi-R36/scripts/assemble-telmi-v20.sh
```

Image produite : `Telmi-R36/output/telmi-r36-v20-<VERSION>.img`  
Fichier `LATEST.txt` indique quelle version flasher.  
Sur la partition BOOT : `TELMI-VERSION.txt`.

### Flash sur une SD (TELMI = tout l’espace restant)

Préférer une image compacte (~4 Go) puis étendre, **ou** écrire directement sur la carte :

```bash
# PowerShell admin : monter le lecteur SD dans WSL
wsl --mount \\.\PHYSICALDRIVEn --bare

# Dans WSL root — voir lsblk pour /dev/sdX
wsl -u root -e bash -lc 'lsblk'

# A) Flash complet (BOOT + root + TELMI max)
wsl -u root -e bash Telmi-R36/scripts/flash-telmi-sd.sh /dev/sdX

# B) Apres Rufus d'une .img 4 Go : agrandir seulement TELMI
wsl -u root -e bash Telmi-R36/scripts/flash-telmi-sd.sh /dev/sdX --expand
```

Voir `CHANGELOG.md` pour l’historique.

## Layout carte SD (slot droite TF-OS)

| Partition | Taille | Contenu |
|-----------|--------|---------|
| p1 BOOT | 500 Mo | Noyau 5.10 + `rf3536k3ka.dtb` (stock V20) |
| p2 root | ~1,5 Go | TelmiOS (binaires, res, Stories/Music/Saves) |

Chemins compatibles Miyoo (symlinks) :

- `/mnt/SDCARD` → `/telmi`
- `/mnt/SDCARD/.tmp_update` → `/opt/telmi`
- Stories : `/telmi/Stories/`
- Musique : `/telmi/Music/`
- Sauvegardes : `/telmi/Saves/`

## Différences Miyoo → R36S

| Miyoo | R36S |
|-------|------|
| `SDL_AUDIODRIVER=mmiyoo` | `alsa` |
| `SDL_VIDEODRIVER=mmiyoo` | `kmsdrm` + swrast |
| ARMv7 32-bit | AArch64 (RK3326) |
| `libshmvar` / `axp` PMIC | Stubs + sysfs batterie |
| `autorun.inf` | `init.d` → `telmi-runtime.sh` (+ `autorun.inf` sur TELMI pour Sync) |
| 752×560 (Plus) / 640×480 | 640×480 |

## État du portage

- [x] Boot direct TelmiOS (runtime, bootScreen, storyTeller)
- [x] Stubs shmvar / axp
- [x] Image légère sans ROMs
- [x] Audio ALSA + MP3 (drmp3) — volume `amixer`
- [x] D-Pad `BTN_DPAD_*` + `ABS_HAT0X/Y`
- [ ] Écran de charge (`chargingState`) — batterie sysfs à calibrer
- [ ] Flash logo personnalisé (spécifique Miyoo PMIC)
- [ ] Partition TELMI visible Telmi Sync sous Windows (p1 vs p3)

## Licence

Telmi est sous GPL-3.0. Voir le dépôt source DantSu/Telmi-story-teller.
