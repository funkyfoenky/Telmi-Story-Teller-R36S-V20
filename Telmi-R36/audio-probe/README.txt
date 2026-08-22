# Audio probe V30 — diagnostic son sans rebuild 2 Go

## But

Isoler le silence HP/casque en enchainant des reglages ALSA + GPIO,
avec log sur la partition TELMI (lisible sous Windows).

## Une fois (root SD)

1. SD flashee en **0.3.4** (ALSA card0 OK).
2. Admin : `Inject-Audio-Probe-Wrapper.bat`
   - installe le wrapper `storyTeller` + copie de secours sous `/opt/telmi/audio-probe`

## A chaque test (TELMI seulement, rapide)

1. `Enable-Audio-Probe.bat` → indique la lettre du volume **TELMI**
2. SD dans la console, boot
3. Ecran change de **couleur** toutes les ~8 s = etape en cours
4. Ecoute HP **et** casque pendant le cycle (~3 min) puis extinction auto
5. Relis `TELMI:\logs\audio-probe.log`
6. Note la ligne `STEP: ...` / couleur si un son apparait

## Desactiver

`Disable-Audio-Probe.bat` (supprime le flag `AUDIO-PROBE`) → boot Telmi normal.

## Modifier la sonde

Edite `TELMI:\audio-probe\run.sh` sous Windows, re-copie si besoin, reboot.
Pas besoin de re-flasher ni de re-injecter le root.

## Couleurs (resume)

| Couleur approx | Etape |
|----------------|--------|
| Vert | Path=SPK |
| Bleu | Path=HP |
| Cyan | Path=SPK_HP |
| Jaune | RING_SPK |
| Orange | RING_SPK_HP |
| Violet | HP_NO_MIC |
| Magenta | tests GPIO ampli + SPK |
| Blanc | SPK_HP + gpio103 |

## Si tu entends quelque chose

Envoie le log + la couleur / le `STEP` entendu — on figera ce reglage dans l’OS V30.
