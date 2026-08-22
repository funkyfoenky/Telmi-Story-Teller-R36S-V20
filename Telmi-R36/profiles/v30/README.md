# Profil TelmiOS — R36S **V30** (legacy)

> **Depuis 0.5.0** : utilisez l’**image unique** + `Select-Telmi-REV.bat` (REV `v30-panel4`).  
> Ce profil et `LATEST-V30.txt` restent pour labo / non-régression.

## Flux recommandé (produit)

```bat
Flash-Telmi-SD.bat
Select-Telmi-REV.bat   → choisir "R36S V30 Panel 4"
```

## Build compact legacy

```bash
bash Telmi-R36/scripts/build-telmi-bins.sh unified storyTeller
bash Telmi-R36/scripts/assemble-telmi-v30-compact.sh
```

Sortie : `output/telmi-r36-v30-<VERSION>.img` + `LATEST-V30.txt`  
Flash : `Flash-Telmi-SD-V30.bat` (DEPRECATED → redirige vers flash unique)

## Notes

- Noyau compact = **5.10** (base V20) + DTB Panel4 porté
- Audio Path = **HP** (SPK silencieux sur Panel4)
- Builds ArkOS 4.4 hors scope image unique
