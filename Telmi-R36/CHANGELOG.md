# TelmiOS R36S — changelog images

## 0.6.6 — 2026-08-25
- **Fix V30 dual-SD (diag 0.6.5)** : slot gauche ne partage plus `vccio_sd` avec l OS
  - `vqmmc` gauche = `vcc_sd` 3.3V fixe (evite course UHS 1.8V de mmc1)
  - UHS retire sur ff380000 ; eMMC fantome ff390000 desactive

## 0.6.5 — 2026-08-25
- Mode **SD-DIAG V30** : flag `/boot/TELMI-SD-DIAG` → inventaire MMC/DTB/GPIO/regulateurs + rescan/pulse, log sur BOOT, extinction (pas de storyTeller)
- Windows : `sd-diag/Enable-SD-Diag.bat` / `Disable-SD-Diag.bat`

## 0.6.4 — 2026-08-25
- **Fix V30 dual-SD (stock DTB)** : slot gauche aligne sur ArkOS / `rk3326-rg351mp-linux`
  - `cd-gpios` : gpio3 pin14 (au lieu de gpio0 pin2 = conflit `wifi chip_en`)
  - `vqmmc-supply` : `vccio_sd` (au lieu de `vcc2v8_dvp`)
- Note : `gameconsole-r36s.dtb` / `rg351mp-kernel.dtb` ont le 2e slot **disabled** — pas de dual-SD

## 0.6.3 — 2026-08-24
- **Fix V30 dual-SD** : panel Panel4 utilisait le meme regulateur (vcc1v8_dvp) que le slot SD gauche — le 2e TF n etait jamais detecte (`host mmc2: cards=0`)
- Panel alimente via `vcc18_lcd_n` ; slot gauche via `vcc_sd` (comme slot OS)

## 0.6.2 — 2026-08-24
- V30 dual-SD : attente 20s + retry 12s, rescan MMC agressif, logs host/cards/blocks
- DTB V30 : `broken-cd` sur les 2 slots SD (detect GPIO souvent faux)
- Fix log runtime si /telmi pas monte (fallback /boot/telmi-runtime.log)

## 0.6.1 — 2026-08-24
- Boot plus rapide : attente dual-SD 8s (au lieu de 25s×2) + splash unique
- DTB V20 stock (fix boot noir depuis 0.5.0)
- Montage BusyBox blkid corrige (carte gauche TELMI)
- Politique : bump mineur (0.6.x) a chaque correctif flashable

## 0.6.0 — 2026-08-24
- **Dual-SD** : OS slot droit (TF-OS) + contenu slot gauche (TF2) pour Telmi Sync
- Montage automatique : carte non-OS prioritaire sur `/telmi` (`telmi-mount-content.sh`)
- Fallback single-SD : p3 TELMI sur carte OS si pas de carte gauche
- Windows : `Prepare-Content-SD.bat`, `Flash-Telmi-SD-OS-Only.bat` (`-Mode os-only`)
- Build : `TELMI_OS_ONLY=1` sur assemble (BOOT + root, sans p3)
- **Fix V20 boot** : `dtb/v20.dtb` = DTB stock (107328 o) — le DTB Telmi 108028 o cassait le boot depuis 0.5.0
- Fix montage BusyBox : parse `blkid` sans `-s/-o` (carte gauche TELMI enfin montee)

## 0.5.0 — 2026-08-22
- **Image unique multi-REV** : `telmi-r36-0.5.0.img` + `Select-Telmi-REV.bat`
- Un seul binaire : quirks V20/V30 via `/boot/TELMI-REV.txt` (audio Path, zed_keyboard)
- BOOT : `dtb/v20.dtb`, `dtb/v30-panel4.dtb`, `revs.json`
- Audio V30 Panel4 : Path=HP (valide par audio-probe)
- bootScreen PNG (logo Boot / Screen_Off)
- DEPRECATED : `Flash-Telmi-SD-V30.bat` / `LATEST-V30.txt` (labo)

## 0.4.8 — 2026-07-28
- Fix crash SIGTRAP timeline : division par 0 dans video_screenWriteFont (ALIGN_LEFT)
- FN : alias multiples + log de tous les codes touche pour diagnostic DTB
- Suppression script extinction auto PC

## 0.4.7 — 2026-07-28
- Bouton FN (BTN_TRIGGER_HAPPY5) = Menu Miyoo : pause + save Saves/ + retour liste
- Inclut correctifs 0.4.6 (timeline/freeze) + volume ALSA Playback (0.4.5)

## 0.4.6 — 2026-07-27
- Fix freeze timeline/pause/seek : suppression thread Mix_LoadMUS (deadlock mixer)
- Position barre via horloge logicielle ; pause/seek affichent l'overlay correctement
- Volume ALSA Playback (depuis 0.4.5)

## 0.4.5 — 2026-07-27
- Volume : ALSA `Playback` (vrai gain HP) — Mix_VolumeMusic ne changeait pas le son audible

## 0.4.4 — 2026-07-27
- Fix regression menus : images ne sont plus effacees par la timeline
- Timeline : overlay a la demande (Start), restore image apres timeout
- Seek ±10s sans freeze (duree sync, join thread avant Mix_SetMusicPosition)
- Volume : plus d'amixer a chaque appui (latence) ; hardware 100% + Mix lineaire

## 0.4.3 — 2026-07-27
- Barre de progression histoires : pause/reprise (Start/Select), seek ±10s (gauche/droite)
- Timeline active aussi sur pages illustrees (overlay a la demande)
- Fallback position/duree audio si Mix_GetMusicPosition renvoie -1 (drmp3)

## 0.4.2 — 2026-07-26
- Vol+/Vol- : ecoute multi `/dev/input/event*` (gpio-keys en plus de la manette)
- Volume aussi sur PRESSED/REPEAT + sync `Mix_VolumeMusic` (pas seulement amixer)

## 0.4.1 — 2026-07-26
- Audio RK3326 : `Playback Path=SPK` (sinon silence HP malgre ALSA OK)
- asound.conf : dmix + buffer (moins d'underruns)
- Logs `[stories]` si `nodes.json` / `startAction` manquant
- Mix_OpenAudio buffer 8192

## 0.4.0 — 2026-07-26
- Audio ALSA : `SDL_AUDIODRIVER=alsa`, `alsa-lib` + `amixer`/`aplay`
- SDL2_mixer : decodeur MP3 `drmp3` (les histoires ne sautent plus les pages)
- Volume hardware via `amixer` (plus `/dev/mi_ao` Miyoo)
- Init `S07telmi-audio` + `/etc/asound.conf`
- Parametres par defaut `Saves/.parameters` + `autorun.inf` (Telmi Sync)
- D-Pad : support `ABS_HAT0X/Y` en plus de `BTN_DPAD_*`
- Logs si `Mix_LoadMUS` / `Mix_Init(MP3)` echoue
- Verif montage `/telmi` avant lancement storyTeller

## 0.3.0 — 2026-07-26
- bootScreen sans SDL (framebuffer `/dev/fb0` direct)
- Probes `sdlprobe` / `sdlprobe-fb` + logs `/boot/sdl-steps.log`
- Mesa panfrost/rockchip désactivés → `kms_swrast`
- Fix : `sed` CRLF ne corrompt plus les binaires ELF
- Image versionnée : `telmi-r36-v20-0.3.0.img`

## 0.2.x — builds précédents (non versionnés)
- Partition TELMI p3, bind-mount `.tmp_update`
- Tentatives SDL kmsdrm (segfaults récurrents)
