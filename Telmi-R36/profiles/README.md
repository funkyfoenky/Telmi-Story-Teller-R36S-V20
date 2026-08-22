# Profils matériels — image unique multi-REV

Depuis **0.5.0**, une seule image `telmi-r36-<VERSION>.img` couvre V20 et V30 Panel4.

| Étape | Action |
|-------|--------|
| Build bins | `bash scripts/build-telmi-bins.sh unified` |
| Assemble | `bash scripts/assemble-telmi-unified.sh` |
| Flash | `Flash-Telmi-SD.bat` |
| Choisir REV | `Select-Telmi-REV.bat` (volume BOOT) |

Catalogue : [`boot/revs.json`](../boot/revs.json)  
DTB : [`boot/dtb/`](../boot/dtb/)

## REV supportés

| id | Label | Audio Path | Notes |
|----|-------|------------|-------|
| `v20` | R36S V20 (clone) | SPK | Défaut après assemble |
| `v30-panel4` | R36S V30 Panel 4 | HP | Ignore `zed_keyboard` fantôme |

Ajouter un REV = nouveau DTB 5.10 dans `boot/dtb/` + entrée dans `revs.json` (pas de nouvelle image).

## Legacy

- `profiles/v20` / `profiles/v30` : docs historiques
- `Flash-Telmi-SD-V30.bat` : DEPRECATED → flash unique + Select-Telmi-REV
- `assemble-telmi-v30-compact.sh` : labo / non-régression
- Images ArkOS 4.4 (~8 Go) : hors scope image unique
