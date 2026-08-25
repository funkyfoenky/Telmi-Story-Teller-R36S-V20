# Audio probe — diagnostic son (labo)

## But

Isoler un silence HP/casque en enchaînant des réglages ALSA + GPIO,
avec log sur la partition TELMI (lisible sous Windows).

Prérequis : image déjà flashee (audio Path V30 = HP depuis 0.5.0).

## Activer

1. `Enable-Audio-Probe.bat` → indiquer la lettre du volume **BOOT** (flag)
2. SD dans la console, boot
3. L’écran change de couleur toutes les ~8 s = étape en cours
4. Écouter HP et casque pendant le cycle, puis extinction auto
5. Relire le log sur TELMI (`logs/audio-probe.log` si présent)

## Désactiver

`Disable-Audio-Probe.bat` → boot Telmi normal.

## Sources

- `run.sh` — séquence de tests
- `fbcolor.c` / `gen_tone.py` — outils de rebuild si besoin
- `storyTeller-wrapper.sh` — wrapper optionnel (déjà intégré en image si probe injectée)
