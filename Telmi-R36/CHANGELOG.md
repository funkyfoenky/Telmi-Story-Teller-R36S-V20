# TelmiOS R36S — changelog images

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
