# Adaptations de Telmi OS pour la R36S

Document destiné à **DantSu**, auteur de [Telmi-story-teller](https://github.com/DantSu/Telmi-story-teller).

Il explique **pourquoi** Telmi OS 1.10.1 (Miyoo Mini / Mini+) ne peut pas tourner tel quel sur une R36S, et **ce qui a dû changer** dans le port `Telmi-R36/`. Le métier (lecteur d’histoires STUdio, lecteur MP3, UI) est conservé. Ce qui change, c’est le socle matériel et surtout le **modèle de carte SD**.

Base upstream inspectée : `DantSu/Telmi-story-teller` tag **1.10.1**, copie locale `Telmi-story-teller-1.10.1/` (dans ce dépôt).

Port actuel : image unique **Telmi-R36 0.6.0**, noyau vendor 5.10, un binaire pour clone V20 et V30 Panel 4, support **dual-SD** (contenu slot gauche).

---

## 1. Contexte

Sur Miyoo Mini, Telmi OS n’est **pas** un Linux complet flashé sur la carte. C’est un **payload applicatif** (héritage Onion) que le firmware Miyoo, déjà présent en NAND, lance depuis la SD :

- le Linux Miyoo (ARMv7 32-bit, driver SDL `mmiyoo`, `/dev/mi_ao`, GPIO/PWM maison) est dans la console ;
- la SD unique, **une seule partition FAT32**, contient à la fois l’app (`.tmp_update/`) et le contenu (`Stories/`, `Music/`, `Saves/`) ;
- Windows voit **toute** la carte. Telmi Sync installe l’OS et synchronise les histoires sur ce volume unique.

La R36S est une autre machine :

- SoC **RK3326, AArch64**, pas de NAND applicative Telmi ;
- boot **100 % carte SD** (chargeur Rockchip + noyau + rootfs) ;
- **deux slots** microSD (TF-OS à droite, TF2 à gauche) ;
- clones **V20** et révisions **V30** avec DTB et codec audio différents.

On ne peut donc pas « copier Telmi OS sur une FAT32 et démarrer ». Il a fallu fabriquer un **vrai OS** (Buildroot) qui héberge Telmi, tout en faisant croire à Telmi Sync et au code C que `/mnt/SDCARD` existe toujours.

Produit actuel (0.6.0+) :

1. **Dual-SD (recommandé)** : `Flash-Telmi-SD-OS-Only.bat` sur slot droit + `Prepare-Content-SD.bat` sur slot gauche + `Select-Telmi-REV.bat`.
2. **Single-SD (legacy)** : `Flash-Telmi-SD.bat` + expand p3 + `Select-Telmi-REV.bat`.
3. Insérer la carte **OS dans le slot droite (TF-OS)** et démarrer.

---

## 2. Architecture des cartes SD — le point central

C’est l’adaptation la plus importante. Tout le reste (SDL, ALSA, boutons) découle du fait qu’on n’est plus sur une Miyoo.

### 2.1 Ce que Telmi OS suppose aujourd’hui (Miyoo)

Le firmware NAND monte la SD en `/mnt/SDCARD` et exécute `.tmp_update/runtime.sh` (`Telmi-story-teller-1.10.1/static/build/.tmp_update/runtime.sh`).

```text
Carte SD Miyoo — 1 partition FAT32 (label TelmiOS-v1.10.1)
│
├── .tmp_update/          OS applicatif
│   ├── bin/              storyTeller, bootScreen, batmon, axp, …
│   ├── lib/              SDL mmiyoo, libpadsp.so, …
│   ├── res/              PNG, polices
│   ├── runtime.sh        point d’entrée
│   └── telmiVersion/
├── Stories/              histoires STUdio
├── Music/                MP3
├── Saves/                .parameters, progression
├── system.json
└── autorun.inf           Telmi Sync reconnaît la carte
```

Chemins C upstream (volontairement conservés côté app) :

- `/mnt/SDCARD/Stories/`
- `/mnt/SDCARD/Music/`
- `/mnt/SDCARD/Saves/.parameters`
- `/mnt/SDCARD/.tmp_update/res/`

Telmi Sync s’appuie sur :

- un volume **FAT32** que Windows peut monter ;
- `autorun.inf` avec un label du type `TelmiOS-v1.10.1` ;
- la présence de `.tmp_update/`, `Stories/`, `Music/`, `Saves/`.

Ça marche parce que **la SD n’a pas à porter le bootloader ni le noyau**. La Miyoo sait déjà démarrer.

### 2.2 Pourquoi une FAT32 unique ne boot pas sur R36S

Le SoC Rockchip RK3326, au reset, ne cherche pas `.tmp_update`. Il cherche un **chargeur dans les tout premiers secteurs** du média, hors table de partitions, puis un noyau + un Device Tree.

Une R36S a en plus **deux lecteurs** :

- **Slot droite, TF-OS / TF1** : slot de boot. Telmi n’utilise que celui-là.
- **Slot gauche, TF2** : stockage optionnel sur ArkOS. **Non utilisé** pour booter Telmi. Une carte « style Telmi Sync » (une FAT32) à gauche ne lancera jamais l’OS.

Chaîne de boot Rockchip (simplifiée) :

```text
ROM SoC
  → idbloader + U-Boot   (octets bruts, ~0–16 Mo, hors partition)
  → partition BOOT FAT32 (noyau Image + .dtb)
  → rootfs ext4          (Linux + /opt/telmi)
```

Windows ne voit pas ext4. Windows ne voit pas le chargeur hors partition. Si on formate la carte en une seule FAT32 comme Telmi Sync le fait sur Miyoo :

- le chargeur Rockchip est détruit ;
- il n’y a plus de noyau ;
- **la console ne s’allume pas**.

D’où une image `.img` à flasher (Rufus / `Flash-Telmi-SD.bat`), et **pas** une installation glisser-déposer de l’OS depuis Telmi Sync.

### 2.3 Layout réel de la carte Telmi-R36 (slot droite)

Assemblage : `Telmi-R36/scripts/assemble-telmi-v20.sh`, puis image unique `Telmi-R36/scripts/assemble-telmi-unified.sh`. Montage : `Telmi-R36/overlay/etc/fstab`.

Table **GPT**. Image compacte ~2,2 Go ; la partition TELMI est ensuite **étendue** à toute la carte (`Expand-Telmi-SD.bat`).

```text
Carte SD — slot TF-OS (droite)
│
│  0 ──────── 16 Mo     Chargeur Rockchip (idbloader + U-Boot)
│                       Hors partition. Invisible sous Windows.
│
├── p1 BOOT   ~500 Mo   FAT32, label BOOT
│     Image                   noyau 5.10
│     rf3536k3ka.dtb          DTB *actif* lu par U-Boot
│     dtb/v20.dtb
│     dtb/v30-panel4.dtb
│     revs.json
│     TELMI-REV.txt           v20 | v30-panel4
│     TELMI-AUDIO-PATH.txt    SPK | HP
│
├── p2 root   ~1,5 Go   ext4, label rootfs
│     Linux Buildroot
│     /opt/telmi/bin/         storyTeller, bootScreen, …
│     /opt/telmi/res/         PNG, polices
│     Invisible sous Windows.
│
└── p3 TELMI  le reste  FAT32, label TELMI
      Stories/  Music/  Games/  Saves/  logs/
      autorun.inf
      .tmp_update/            bind-mount, pas une vraie copie des binaires
      Seul volume que Windows / Telmi Sync doit utiliser.
```

Offsets typiques de l’assembleur V20 :

- chargeur : secteurs 0–32767 (16 Mo) ;
- p1 BOOT : à partir du secteur 32768, ~500 Mo ;
- p2 root : à partir du secteur 1056768, 1536 Mo ;
- p3 TELMI : tout le reste jusqu’à la fin de la carte (après expand).

`fstab` sur la console :

```text
/dev/mmcblk1p2   /        ext4
/dev/mmcblk1p1   /boot    vfat
# /telmi monte par S06telmi-content (dual-SD : autre mmcblk d'abord, sinon p3 OS)
```

`mmcblk1` = TF-OS (droite) **en général**. Sur certains lots / images V30, le slot OS apparaît en `mmcblk0`. Le script `telmi-mount-content.sh` déduit la carte OS via `findmnt /` et monte l’**autre** `mmcblk*` en priorité (slot gauche).

### 2.4 Le pont de compatibilité

Le code C de Telmi 1.10.1 est plein de `/mnt/SDCARD/...`. Réécrire tous les chemins n’apporte rien. On reconstitue **l’illusion Miyoo** au-dessus du layout Rockchip.

```text
PC Windows                         R36S (slot droite)
─────────                          ──────────────────
Telmi Sync
    │
    ▼
Volume FAT32 « TELMI » (p3)  ──►  montage  /telmi
                                       │
                                       ├── symlink
                                       │     /mnt/SDCARD  →  /telmi
                                       │
                                       └── bind-mount
                                             /opt/telmi  →  /telmi/.tmp_update
                                                      ▲
                                                      │
                                              p2 ext4 (binaires AArch64)
```

Trois pièces.

**1. Symlink `/mnt/SDCARD` → `/telmi`**

Créé à l’install rootfs dans `Telmi-R36/external/telmi-r36/package/telmi-r36s/telmi-r36s.mk` :

```make
ln -sf /telmi $(TARGET_DIR)/mnt/SDCARD
```

Tous les `#define` upstream restent valides (`Stories/`, `Music/`, `Saves/.parameters`, `.tmp_update/res/`).

**2. Bind-mount `/opt/telmi` → `/telmi/.tmp_update`**

Fait au boot par `Telmi-R36/overlay/etc/init.d/S06telmi-content` (et à nouveau par `telmi-runtime.sh`).

Sur Miyoo, `.tmp_update/` **est** le dossier des binaires, sur la FAT.  
Sur R36S, les binaires sont **AArch64**, liés contre le rootfs (SDL2 kmsdrm, ALSA). Les mettre sur FAT32 serait lent, fragile (attributs Windows), et Telmi Sync pourrait les écraser avec des ELF 32-bit Miyoo.

Le bind expose donc `/opt/telmi` (ext4) sous le chemin historique `.tmp_update/`. Telmi Sync **voit** encore `.tmp_update/res/` et `autorun.inf`. Les ELF 64-bit ne sont pas ceux que Sync écrirait depuis une build Miyoo.

**3. `autorun.inf` sur p3**

Même contrat que l’upstream `Telmi-story-teller-1.10.1/static/build/autorun.inf`. `S06telmi-content` le crée s’il manque :

```ini
[autorun]
icon  = .tmp_update/res/sdcard.ico
label = TelmiOS-v1.10.3
```

C’est ce qui permet à Telmi Sync de **reconnaître** le volume TELMI comme une carte Telmi OS.

### 2.5 Conséquences pour Telmi Sync et l’installation

- **Installer l’OS** (bouton Telmi Sync sur Miyoo) n’est plus possible : Sync ne peut pas écrire le chargeur Rockchip ni le rootfs ext4. L’OS s’installe en **flashant l’image** `.img`.
- **Synchroniser histoires / musique** : sur le volume `TELMI` — en **dual-SD**, c’est la carte **slot gauche** (retirée et mise dans le PC pour Telmi Sync). En single-SD, c’est p3 sur la carte OS.
- Après flash single-SD, p3 est petite (~100 Mo). **`Expand-Telmi-SD.bat`** agrandit p3. En dual-SD, **`Prepare-Content-SD.bat`** formate toute la carte gauche.
- Changer de console (clone V20 vs V30 Panel 4) ne re-flashe **pas** le contenu : `Select-Telmi-REV.bat` ne copie qu’un DTB vers `rf3536k3ka.dtb` et écrit `TELMI-REV.txt` / `TELMI-AUDIO-PATH.txt` sur **BOOT**.

### 2.6 Deux slots — OS à droite, contenu à gauche (0.6.0+)

```text
R36S vue de face
┌─────────────────────────────────┐
│                                 │
│   [TF2 gauche]    [TF-OS droite]│
│  CONTENU Telmi      BOOT OS     │
│  Telmi Sync PC      OBLIGATOIRE │
└─────────────────────────────────┘
```

- **Slot droit** : chargeur Rockchip + BOOT + root (jamais retiré pour Sync).
- **Slot gauche** : FAT32 label `TELMI`, montée sur `/telmi` au boot (`telmi-mount-content.sh`).
- Stub `.tmp_update/res/` sur la carte contenu pour que Telmi Sync reconnaisse le volume hors console (pas de binaires OS sur cette carte).
- **Fallback single-SD** : si pas de carte gauche, montage de p3 sur la carte OS (comportement 0.5.x).

Mettre **seulement** la carte contenu à droite : écran noir (pas de chargeur OS).

---

## 3. HAL matériel — ce qui remplace la couche Miyoo

Le cœur métier (`stories_reader.h`, `music_player.h`, paramètres, UI) est repris. Les fichiers **système** de `src/common/system/` ne parlent plus le dialecte Miyoo. Équivalents R36S dans `Telmi-R36/platform/r36s/`.

Compilation : `-DPLATFORM_R36S`, toolchain AArch64 Buildroot ([AndreRenaud/buildroot-r36s](https://github.com/AndreRenaud/buildroot-r36s)), pas le `miyoomini-toolchain` Cortex-A7 32-bit de `Telmi-story-teller-1.10.1/src/common/config.mk`.

### 3.1 Vidéo / SDL

**Miyoo.** `runtime.sh` exporte :

```sh
SDL_VIDEODRIVER=mmiyoo
SDL_AUDIODRIVER=mmiyoo
EGL_VIDEODRIVER=mmiyoo
```

C’est un backend **propriétaire** (framebuffer SigmaStar + mixage audio maison). `bootScreen` et `storyTeller` ouvrent une fenêtre SDL classique ; le driver parle au chipset.

**R36S.** Pas de `mmiyoo`. Le chemin qui tient :

- `SDL_VIDEODRIVER=kmsdrm`
- rendu **logiciel** Mesa (`MESA_LOADER_DRIVER_OVERRIDE=kms_swrast`, `GALLIUM_DRIVER=softpipe`, `LIBGL_ALWAYS_SOFTWARE=1`)

Panfrost / `rockchip_dri.so` **plantent** sur le noyau vendor 5.10 des clones V20. D’où, au boot, le déplacement des `.so` GPU hors de `/usr/lib/dri/` (`telmi-runtime.sh` et le `.mk` du paquet). Telmi est du 2D 640×480 : le software rasterizer suffit.

`display.h` Miyoo fait un `mmap` de `/dev/fb0`, allume l’écran via **GPIO 4**, et règle la luminosité par **PWM** (`pwmchip0/pwm0/duty_cycle`). Sur R36S (`Telmi-R36/platform/r36s/system/display.h`) :

- SDL/KMS possède déjà le framebuffer : un second mmap + blank `fb0` **éteint l’écran** (conflit KMS). `display_setScreen(true)` se contente d’écrire `0` dans `/sys/class/graphics/fb0/blank` ; on **ne blank jamais** pour éteindre.
- Luminosité : `/sys/class/backlight/*/brightness` (pwm-backlight du DTB), pas le PWM Miyoo. Échelle Telmi 0–10 conservée, plancher ~4 % pour ne pas croire à un écran mort.

### 3.2 Audio

**Miyoo.** `src/common/system/volume.h` parle à `/dev/mi_ao` (`MI_AO_SETVOLUME` / `SETMUTE`), courbe log 0–20 + boost jusqu’à 25. Le driver `mmiyoo` sort le son.

**R36S.** Codec analogique type RK817 (ou clone). Sans le contrôle mixeur **`Playback Path`**, le DAC tourne et **le haut-parleur reste muet**.

- V20 clone : chemin **`SPK`**
- V30 Panel 4 : chemin **`HP`** (SPK est silencieux sur ce panneau)

Réglage au boot dans `telmi-runtime.sh` selon `/boot/TELMI-REV.txt`, surcharge possible `/boot/TELMI-AUDIO-PATH.txt`. Volume applicatif : SDL_mixer reste à fond ; le **vrai gain** est le contrôle ALSA `Playback` (0–255) via ioctl `SNDRV_CTL_IOCTL_ELEM_WRITE` — pas un `amixer` forké à chaque appui. Voir `Telmi-R36/platform/r36s/system/volume.h`.

`asound.conf` : plugin **dmix** 44100 Hz, période 1024, buffer 8192, pour limiter les underruns SDL_mixer.

Décodage MP3 : Buildroot livrait SDL2_mixer **sans** MP3. Les pages d’histoires sautaient (`Mix_LoadMUS` échoue). Patch du paquet : `--enable-music-mp3-drmp3`.

### 3.3 Boutons

**Miyoo.** Un seul `/dev/input/event0`. Codes **clavier** (`src/common/system/keymap_hw.h`) :

- D-pad = `KEY_UP` / `KEY_DOWN` / `KEY_LEFT` / `KEY_RIGHT`
- A = `KEY_SPACE`, B = `KEY_LEFTCTRL`, …
- Menu = `KEY_ESC`

`storyTeller.c` ouvre uniquement `event0`.

**R36S.** Plusieurs nœuds `event*` :

- pad : `BTN_SOUTH` / `BTN_EAST` / `BTN_DPAD_*` ou chapeau `ABS_HAT0X` / `ABS_HAT0Y`
- Vol+ / Vol− et Power souvent sur un **autre** `gpio-keys`
- clones : Select/Start parfois `BTN_TRIGGER_HAPPY*` au lieu de `BTN_SELECT` / `BTN_START`
- bouton **FN** (équivalent Menu Miyoo) : plusieurs codes selon DTB (`BTN_TRIGGER_HAPPY5`, `KEY_FN`, …)

Le port ouvre **tous** les `event*` utiles, synthétise le D-pad depuis le hat, et mappe FN → menu (pause + save + retour liste). Fichiers : `platform/r36s/system/keymap_hw.h`, boucle d’entrée dans `platform/r36s/storyTeller/storyTeller.c`.

Quirk V30 : un périphérique fantôme `zed_keyboard` envoie VOL− collé au boot. Si `TELMI-REV` est une famille `v30`, on **ignore** ce nœud (`telmi_ignore_zed_keyboard()` dans `platform/r36s/system/telmi_rev.h`). Sur V20, le même nom de nœud est parfois le **vrai** volume : on ne l’ignore pas.

### 3.4 bootScreen

Upstream `src/bootScreen/bootScreen.c` : SDL + PNG depuis `.tmp_update/res/`. Au tout début du boot R36S, KMS/SDL n’est pas encore fiable (et on veut un splash **avant** Mesa). Version R36S : **libpng + blit direct sur `/dev/fb0`**, sans SDL. Fichier : `Telmi-R36/platform/r36s/bootScreen.c`.

### 3.5 Batterie, AXP, logo NAND

`runtime.sh` Miyoo :

- appelle `axp` pour distinguer Mini (283) et Mini+ (354) ;
- lit GPIO 59 (charge) sur Mini ;
- peut **flasher un logo** dans la NAND (`Saves/.flashLogo` + `flash_logo.sh`).

R36S : pas de PMIC AXP Miyoo, pas de NAND logo. `axp` est un **stub** qui retourne 1 (mode « pas AXP »). `batmon` lit `/sys/class/power_supply/battery/capacity` et écrit `/tmp/percBat`. Le flash de logo custom est **inapplicable**.

`/tmp/deviceModel` est forcé à `283` et `/tmp/screen_resolution` à `640x480` (pas de 752×560 Miyoo récente).

### 3.6 Une image, plusieurs révisions

Les clones R36S ne partagent pas le même panneau LCD ni le même routage HP/SPK. Upstream Telmi n’a pas ce problème (deux modèles Miyoo, détection runtime `axp`).

Plutôt que deux images :

- **un** binaire, quirks lus dans `/boot/TELMI-REV.txt` ;
- catalogue `Telmi-R36/boot/revs.json` ;
- U-Boot charge toujours le fichier **fixe** `rf3536k3ka.dtb` ; le sélecteur Windows **remplace ce fichier** par `dtb/v20.dtb` ou `dtb/v30-panel4.dtb`.

Le DTB stock V30 (noyau 4.4 ArkOS) **n’est pas** compatible avec le noyau 5.10 de l’image unique. Le DTB V30 Panel 4 a été **porté** sur l’arbre 5.10. Les images ArkOS 4.4 ~8 Go restent du labo, hors produit.

---

## 4. Adaptations dans storyTeller (métier conservé, runtime cassé)

Répertoire : `Telmi-R36/platform/r36s/storyTeller/`. Format STUdio (`nodes.json`, `images/`, `audios/*.mp3`) inchangé.

### 4.1 Horloge audio / timeline

Sur Miyoo, `Mix_GetMusicPosition` / `Mix_SetMusicPosition` / un thread `Mix_LoadMUS` pour la durée fonctionnent avec le mixer `mmiyoo`.

Avec **drmp3** + ALSA dmix sur RK3326 :

- `Mix_GetMusicPosition` peut renvoyer -1 ;
- charger la durée dans un **thread** pendant que le mixer joue → **deadlock** (freeze timeline / pause / seek).

Le port utilise une **horloge logicielle** (temps wall-clock depuis le play, pause = gel) et un seek **différé / coalescé** (~120 ms) pour ne pas marteler `Mix_SetMusicPosition`. Si `Mix_LoadMUS` échoue, on n’enchaîne plus toutes les pages en « autoplay silencieux ».

### 4.2 Volume et touches volume

Les boutons Vol+/Vol− n’arrivent plus forcément sur le même `event` que le pad : d’où le scan multi-fd. Le volume UI 0–25 est projeté sur le hardware 0–255 (mi-course UI ≈ ancien 80 % qui « sonnait juste »).

### 4.3 Menu / FN

Menu Miyoo (`KEY_ESC`) n’existe pas tel quel. FN R36S joue ce rôle : pause, écriture dans `Saves/`, retour à la liste.

### 4.4 Extension hors Telmi OS (à ne pas confondre avec l’upstream)

Un navigateur de jeux + cœurs libretro (GB, GBA, NES, MD, SNES, PSX) a été ajouté sur la partition TELMI (`Games/…`). Ce n’est **pas** requis pour Telmi OS ; c’est une greffe R36S. DantSu peut l’ignorer pour comprendre le port du story teller.

---

## 5. Boot et runtime — remplacement de `runtime.sh`

Upstream `runtime.sh` fait tout dans un seul script lancé par le firmware Miyoo :

- `axp` / GPIO charge / `chargingState` ;
- PWM backlight + `jsonval` Miyoo ;
- résolution via `/proc/mi_modules/fb/mi_fb0` ;
- horloge sauvegardée (pas de RTC fiable) ;
- `LD_PRELOAD=libpadsp.so storyTeller` ;
- `bootScreen End` + `shutdown` sur `/tmp/.offOrder`.

Sur R36S il n’y a pas de firmware parent. Buildroot BusyBox lance `init.d` :

1. **S05boot** — monte `/boot` (p1 FAT), pour logs et `TELMI-REV.txt`.
2. **S06telmi-content** — monte `LABEL=TELMI` sur `/telmi`, crée `Stories/` `Music/` `Saves/`, `autorun.inf`, bind `.tmp_update`.
3. **S07telmi-audio** — attend `controlC0`, unmute, `Playback Path` (complété ensuite par le runtime selon REV).
4. **S98telmi-fb** — unblank `fb0`.
5. **S99telmi** — splash `bootScreen Boot`, lance `telmi-runtime.sh` en arrière-plan.

Le runtime R36S (`Telmi-R36/overlay/opt/telmi/bin/telmi-runtime.sh`) : Mesa swrast, ALSA, wait carte son, `Playback Path` SPK/HP, `storyTeller` via kmsdrm, puis `bootScreen End` + `poweroff -f` quand `/tmp/.offOrder` apparaît. Plus de `libpadsp`, plus de `/customer/app/jsonval`, plus de `/proc/ls` (init LCD Miyoo).

---

## 6. Ce qui n’a pas changé

Le contrat « contenu » est le même que Telmi OS 1.10.1 :

- histoires STUdio sous `Stories/<nom>/` (`nodes.json`, `title.png` / `title.mp3`, `images/`, `audios/`) ;
- musique sous `Music/*.mp3` ;
- `Saves/.parameters` (JSON volume, luminosité, timeouts, tuiles, night mode, timeline) ;
- `autorun.inf` label `TelmiOS-v1.10.3` pour Telmi Sync ;
- UI storyTeller / music player (carrousel, night mode, lock, autosleep) largement reprise des headers métier ;
- résolution **640×480**.

Les binaires ne sont plus des ELF ARMv7 avec `rpath=/mnt/SDCARD/.tmp_update/lib` : ce sont des ELF AArch64 liés au SDL2/ALSA du rootfs. Le comportement utilisateur visé est le même.

---

## 7. Limites et implications produit

- **Telmi Sync ne peut plus installer l’OS.** Sync synchronise le volume `TELMI` (carte gauche en dual-SD, ou p3 en single-SD). Ne pas toucher BOOT.
- **Dual-SD** : carte OS petite (8–16 Go suffisent) ; carte contenu 32–128 Go pour histoires.
- **Mauvais DTB = écran noir** (très fréquent sur clones). D’où le sélecteur REV sur BOOT, sans rebuilder.
- **GPU 3D inutilisable** (swrast). Acceptable pour Telmi 2D ; un port « jeu 3D » n’est pas ce produit.
- **Pas de flash logo NAND**, pas de détection Mini vs Mini+ via AXP.
- **Hot-plug** carte gauche après boot : non supporté en v1 (reboot requis).

---

## 8. Carte d’orientation des fichiers

Pour relier ce document au dépôt :

- Upstream Miyoo : `Telmi-story-teller-1.10.1/`
- HAL + apps R36S : `Telmi-R36/platform/r36s/`
- Overlay Linux (fstab, init, ALSA, runtime) : `Telmi-R36/overlay/`
- Montage dual-SD : `overlay/opt/telmi/bin/telmi-mount-content.sh`
- Contenu seed : `Telmi-R36/content/` + `Prepare-Content-SD.bat`
- Catalogue REV / DTB : `Telmi-R36/boot/`
- Image unique : `scripts/assemble-telmi-unified.sh` + `Select-Telmi-REV.bat`
- Changelog des leçons hardware : `Telmi-R36/CHANGELOG.md`

En une phrase : **Telmi OS reste Telmi OS ; la R36S impose un Linux bootable sur SD, donc on a séparé « ce que Windows a le droit de voir » (p3 TELMI) et « ce qui fait démarrer la console » (chargeur + BOOT + rootfs), puis recollé les deux avec un symlink et un bind-mount pour ne pas casser les chemins `/mnt/SDCARD` ni Telmi Sync.**
