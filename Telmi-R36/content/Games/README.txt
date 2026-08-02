TelmiOS — dossier Games

Structure :
  Games/
    gb/          Game Boy (.gb)                 — emu Peanut-GB
    gbc/         Game Boy Color (.gbc)          — core Gambatte
    gba/         Game Boy Advance (.gba)        — core mGBA
    nes/         NES (.nes)                     — core FCEUmm
    md/          Megadrive (.md .gen .smd .bin) — core PicoDrive
    snes/        SNES (.sfc .smc)               — core Snes9x 2005
    psx/         PlayStation (.cue .chd .pbp .iso) — core PCSX ReARMed

BIOS PlayStation (requis) :
  Copiez scph5501.bin / scph1001.bin / scph5502.bin dans Saves/
  (systeme dir libretro = /telmi/Saves)

Jaquette optionnelle : meme nom que la ROM en .png a cote
  ex. Games/nes/mario.nes + Games/nes/mario.png
  Pour PSX : Games/psx/monjeu.cue + Games/psx/monjeu.png

Sauvegardes auto (MENU/FN pour quitter) :
  Saves/states/<nom_rom>.state   — save state (reprise exacte)
  Saves/states/<nom_rom>.sav     — sauvegarde cartouche (SRAM)

Menu (combinaison configurable, defaut Select x3 sur le carrousel Telmi) :
  Configurer dans Telmi Sync → Jeux → « Combo menu caché »
  (clé gameUnlockCombo dans Saves/.parameters)
  1) Choisir la console
  2) Choisir le jeu dans la grille
  Quitter l'emu : MENU / FN
  Retour liste : X / Y
