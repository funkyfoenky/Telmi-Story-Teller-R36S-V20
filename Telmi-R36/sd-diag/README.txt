# Telmi V30 — diagnostic SD (un seul boot)

## But

Inventaire complet des slots MMC + DTB + GPIO CD + regulateurs + rescan/pulse,
sans lancer storyTeller. Rapport sur la partition BOOT (lisible Windows).

## Activer

1. Image Telmi >= 0.6.5 flashee OS-only
2. Select-Telmi-REV -> v30-panel4
3. Sur le PC :
   - Windows : Enable-SD-Diag.bat -> lettre du volume BOOT
   - Linux / macOS : bash enable-sd-diag.sh  (ex. /Volumes/BOOT)
4. Carte OS slot droit + carte contenu slot gauche
5. Boot : couleurs ecran = phases, puis extinction auto (~1 min)

## Lire le resultat

Sur BOOT (apres extinction) :

- telmi-sd-diag-VERDICT.txt  (resume 1 page)
- telmi-sd-diag.log          (detail complet)

## Desactiver

Windows : Disable-SD-Diag.bat
Linux / macOS : bash disable-sd-diag.sh
(supprime TELMI-SD-DIAG sur BOOT) -> boot Telmi normal.

## Couleurs (approx)

| Couleur | Phase |
|---------|--------|
| Vert | A inventaire MMC |
| Bleu | B device-tree |
| Jaune | C GPIO CD |
| Violet | D regulateurs |
| Orange | E dmesg + rescan + pulse |
| Cyan | F mounts |
| Blanc | G verdict |

## Note

Le DTB ne change pas en live. Ce diag explique pourquoi mmc2 reste cards=0
et oriente le prochain patch (GPIO / alim / pinctrl).
