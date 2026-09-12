# Telmi — diagnostic boot Y3506 / panel inconnu

## Deux modes diagnostic

| Mode | Flag | DSI | Usage |
|------|------|-----|--------|
| **Boot-diag** | `TELMI-BOOT-DIAG` | **OFF** | Linux vit-il sans MIPI ? |
| **Panel-diag** | `TELMI-PANEL-DIAG` | **ON** | Logs pendant un vrai test panel (v05d…) |

### Panel-diag (0.6.8+, MIPI actif)

1. Flasher image >= 0.6.8
2. DTB panel normal → `rf3536k3ka.dtb` (ex. `y3506-v05d.dtb`)
3. `Enable-Panel-Diag.bat` (crée `TELMI-PANEL-DIAG`, **pas** boot-diag)
4. Boot — même si écran noir / OFF ~15 s
5. Remettre la SD dans le PC, lire BOOT :

| Fichier | Signification |
|---------|---------------|
| `telmi-panel-diag-VERDICT.txt` | Userspace a tourné **avec DSI actif** |
| `telmi-panel-diag.log` | dmesg panel/DSI + heartbeat 25 s |
| `telmi-panic-prev.log` | **Panic noyau du boot précédent** (si mort avant userspace) |

Si seul `telmi-panic-prev.log` contient du texte → le noyau a panic au probe MIPI ; relire les lignes `dsi`/`panel`/`panic`.

Désactiver : `Disable-Panel-Diag.bat`

## Demarrage rapide boot-diag (Windows)

1. Inserez la carte OS (slot droit), ouvrez le volume **BOOT**
2. Double-clic : **`Prepare-Y3506-Bootdiag.bat`**
3. Bootez la Y3506, attendez **30–40 s**
4. Remettez la SD dans le PC, lisez sur BOOT :
   - `telmi-boot-diag-VERDICT.txt` (image >= 0.6.7 ou SD injectee)
   - `telmi-boot-diag.log`

Image **0.6.6** sans inject : observation seule (console reste allumee ?).
Inject rootfs : `sudo bash scripts/inject-boot-diag-into-sd.sh /dev/sdX`

## Limite honnete

On **ne peut pas** faire un OS qui “trouve tout seul” le bon panel sans :
- soit un **UART série** (log noyau en live),
- soit une **matrice de DTB** testés un par un (ce pack),
- soit un boot **headless** qui prouve que Linux démarre et écrit un log sur BOOT.

Si le noyau meurt dans U-Boot / au probe MIPI **avant** le userspace, aucun script ne tournera. D’où le DTB `y3506-bootdiag.dtb` (DSI coupé).

## Deux modes

### A) Matrice DTB seule (marche sur image **0.6.6** déjà flashée)

Sur volume **BOOT**, écraser `rf3536k3ka.dtb` + `TELMI-REV.txt` + `TELMI-AUDIO-PATH.txt=HP`.

Ordre strict (un test = un boot = une observation) :

| # | Fichier → `rf3536k3ka.dtb` | REV | Observation attendue |
|---|---------------------------|-----|----------------------|
| 0 | `y3506-bootdiag.dtb` | `y3506-bootdiag` | **Prioritaire.** Pas d’écran utile. Laisser 30–40 s. Si la console **reste allumée** (LED / conso) plus longtemps qu’avant → Linux vit probablement. |
| 1 | `y3506-t-panel4.dtb` | `y3506-t-panel4` | Panel4 stock Telmi |
| 2 | `y3506-t-timings.dtb` | `y3506-t-timings` | Init Panel4 + clock Y3506 |
| 3 | `y3506-t-init.dtb` | `y3506-t-init` | Timings Panel4 + init DarkOS |
| 4 | `y3506-v05b.dtb` | `y3506-v05b` | (déjà testé KO) |

Pour chaque test, noter : `batterie→OFF` / `noir` / `logo Telmi` / `reste allumé sans image`.

### B) Boot-diag avec log Windows (image **≥ 0.6.7** requise)

1. Flasher image avec `telmi-boot-diag.sh` dans le rootfs
2. `rf3536k3ka.dtb` = `y3506-bootdiag.dtb`
3. Activer : `Enable-Boot-Diag.bat` (crée `TELMI-BOOT-DIAG` sur BOOT)
4. Boot 30–40 s (écran peut rester noir)
5. Remettre la SD dans le PC → lire :
   - `BOOT:\telmi-boot-diag-VERDICT.txt`
   - `BOOT:\telmi-boot-diag.log`

**Si VERDICT présent** → Linux démarre ; on itère seulement sur le panel.  
**Si aucun fichier** → plantage avant userspace (noyau / DTB / chargeur) → UART ou autre base noyau.

## Activer / désactiver le flag (0.6.7+)

```
Enable-Boot-Diag.bat
Disable-Boot-Diag.bat
```

## Fichiers DTB (dossier `Telmi-R36/boot/dtb/`)

- `y3506-bootdiag.dtb`
- `y3506-t-panel4.dtb`
- `y3506-t-init.dtb`
- `y3506-t-timings.dtb`
- `y3506-v05b.dtb` / `y3506-v05.dtb` (legacy)

Régénérer la matrice :

```bash
python3 scripts/port-y3506-diag-matrix.py \
  --base boot/dtb/v30-panel4.dtb \
  --y3506 "dtb_backup/Y3506_V05_20251215 2601/rk3326-r36s-linux.dtb" \
  --outdir boot/dtb
```
