# Telmi-R36 — TelmiOS pour R36S (image unique multi-REV)

Portage de **Telmi story teller 1.10.3** vers **R36S** (V20 clone, V30 Panel4) en OS dédié.

## Flux dual-SD (recommandé depuis 0.6.0)

```text
Slot DROIT (TF-OS)  : OS Telmi — flash une seule fois
Slot GAUCHE (TF2)   : contenu Stories/Music — Telmi Sync sur PC

1. Flash-Telmi-SD-OS-Only   (.bat Windows / .sh Linux-macOS)
2. Prepare-Content-SD       (carte gauche, label TELMI)
3. Select-Telmi-REV         (volume BOOT sur carte droite)
4. Boot : contenu monté depuis slot gauche sur /telmi
```

## Flux single-SD (legacy)

```text
1. Flash-Telmi-SD
2. Select-Telmi-REV
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

## Flash / préparation SD

Même flux sur **Windows**, **Linux** et **macOS**. Les `.bat` restent l’entrée Windows ; les `.sh` élèvent via `sudo` et listent les disques amovibles.

| Action | Windows | Linux / macOS |
|--------|---------|----------------|
| OS slot droit, sans expand | `Flash-Telmi-SD-OS-Only.bat` | `bash Flash-Telmi-SD-OS-Only.sh` |
| Flash + expand p3 (single-SD) | `Flash-Telmi-SD.bat` | `bash Flash-Telmi-SD.sh` |
| Carte contenu slot gauche | `Prepare-Content-SD.bat` | `bash Prepare-Content-SD.sh` |
| Expand p3 seul | `Expand-Telmi-SD.bat` | `bash Expand-Telmi-SD.sh` |
| V20 / V30 / Y3506 sur BOOT | `Select-Telmi-REV.bat` | `bash Select-Telmi-REV.sh` |
| Diagnostic slot gauche V30 | `sd-diag/Enable-SD-Diag.bat` | `bash sd-diag/enable-sd-diag.sh` |

### Linux / macOS — prérequis

```bash
# Debian / Ubuntu
sudo apt install gdisk dosfstools parted

# Fedora
sudo dnf install gdisk dosfstools parted

# Arch
sudo pacman -S gptfdisk dosfstools parted

# macOS (Homebrew) — newfs_msdos est natif
brew install gptfdisk
```

Placez `output/telmi-r36-<VERSION>.img` + `output/LATEST.txt`, branchez la SD, puis :

```bash
# Interactif (liste les disques USB/SD, confirmation FLASH / PREPARE)
bash Flash-Telmi-SD-OS-Only.sh
bash Prepare-Content-SD.sh
bash Select-Telmi-REV.sh

# Ou device explicite
sudo bash scripts/flash-telmi-sd.sh /dev/sdX --os-only --yes      # Linux
sudo bash scripts/flash-telmi-sd.sh disk4 --from-image            # macOS
```

Sur macOS, l’écriture utilise `/dev/rdiskN` (plus rapide). `sgdisk` doit rester visible sous `sudo` (le script préfixe `/opt/homebrew` et `/usr/local`).

Le **build** de l’image (cross-compile, `assemble-telmi-unified.sh`) reste Linux / WSL.

## Layout cartes

**Slot droit (OS)** — GPT : p1 BOOT | p2 root | p3 TELMI (single-SD seulement)  
**Slot gauche** — 1 partition FAT32 label `TELMI`

Montage runtime : `overlay/opt/telmi/bin/telmi-mount-content.sh`

Voir `CHANGELOG.md` et `docs/ADAPTATIONS-TELM-R36S.md`.
