#ifndef VOLUME_H__
#define VOLUME_H__

/* Volume R36S : controle ALSA direct via ioctl (pas de fork/exec amixer).
 * Mix reste a fond ; le vrai gain est le controle ALSA "Playback" (0-255). */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sound/asound.h>

#include <SDL2/SDL_mixer.h>

#include "system/telmi_rev.h"
#include "utils/file.h"

#define MAX_VOLUME 20

static int r36s_spk_ready = 0;
static int r36s_last_hw = -1;
static int r36s_mixer_fd = -1;
static int r36s_playback_numid = -1;

static void r36s_ensure_spk_path(void)
{
	char cmd[128];

	if (r36s_spk_ready)
		return;
	snprintf(cmd, sizeof(cmd),
		 "amixer -c 0 -q cset name='Playback Path' %s 2>/dev/null || true",
		 telmi_audio_path());
	system(cmd);
	r36s_spk_ready = 1;
}

/* Trouve le numid du control "Playback" et ouvre le mixer une seule fois. */
static void r36s_mixer_init(void)
{
	struct snd_ctl_elem_list elist;
	struct snd_ctl_elem_id *ids = NULL;
	unsigned int i;

	if (r36s_mixer_fd >= 0)
		return;

	r36s_mixer_fd = open("/dev/snd/controlC0", O_RDWR);
	if (r36s_mixer_fd < 0)
		return;

	memset(&elist, 0, sizeof(elist));
	if (ioctl(r36s_mixer_fd, SNDRV_CTL_IOCTL_ELEM_LIST, &elist) < 0)
		return;
	if (elist.count == 0)
		return;

	ids = (struct snd_ctl_elem_id *)calloc(elist.count, sizeof(*ids));
	if (!ids)
		return;
	elist.space = elist.count;
	elist.pids = ids;
	if (ioctl(r36s_mixer_fd, SNDRV_CTL_IOCTL_ELEM_LIST, &elist) < 0) {
		free(ids);
		return;
	}

	for (i = 0; i < elist.count; i++) {
		if (strcmp((const char *)ids[i].name, "Playback") == 0) {
			r36s_playback_numid = ids[i].numid;
			break;
		}
	}
	free(ids);
}

/* Applique la valeur hw (0-255) directement via ioctl — pas de fork amixer. */
static int r36s_set_playback_hw(int hw)
{
	struct snd_ctl_elem_value ev;

	r36s_mixer_init();
	if (r36s_mixer_fd < 0 || r36s_playback_numid < 0) {
		/* Fallback amixer si ioctl indisponible */
		char cmd[160];
		if (hw <= 0)
			system("amixer -c 0 -q sset Playback 0 mute 2>/dev/null || true");
		else {
			snprintf(cmd, sizeof(cmd),
				 "amixer -c 0 -q sset Playback %d unmute 2>/dev/null || true", hw);
			system(cmd);
		}
		return 0;
	}

	memset(&ev, 0, sizeof(ev));
	ev.id.numid = r36s_playback_numid;
	ev.value.integer.value[0] = hw;
	ev.value.integer.value[1] = hw;
	ioctl(r36s_mixer_fd, SNDRV_CTL_IOCTL_ELEM_WRITE, &ev);

	return 0;
}

int setVolumeRaw(int value, int add)
{
	(void)add;
	return value;
}

/* Convertit volume UI 0..25 → Playback HW 0..255.
 * Ancrage : UI 50% (=12/25) = ancien niveau 80% (hw 204), qui sonnait
 * comme un vrai "mi-volume". Au-dessus, on amplifie jusqu'au max HW. */
static int r36s_volume_to_hw(int volume)
{
	int hw;

	if (volume <= 0)
		return 0;

	if (volume <= 12) {
		/* 1..12 → ~17..204  (0..50% UI = 0..80% de l'ancienne echelle) */
		hw = (volume * 204) / 12;
	} else {
		/* 13..25 → 204..255  (50..100% UI = amplification haute) */
		hw = 204 + ((volume - 12) * (255 - 204)) / (25 - 12);
	}

	if (hw < 40)
		hw = 40;
	if (hw > 255)
		hw = 255;
	return hw;
}

/* volume : 0..25 (echelle Telmi / system.json) */
int setVolume(int volume)
{
	int hw;

	if (volume < 0)
		volume = 0;
	if (volume > 25)
		volume = 25;

	r36s_ensure_spk_path();

	Mix_Volume(-1, MIX_MAX_VOLUME);
	Mix_VolumeMusic(MIX_MAX_VOLUME);

	hw = r36s_volume_to_hw(volume);

	if (hw == r36s_last_hw)
		return volume;
	r36s_last_hw = hw;

	r36s_set_playback_hw(hw);

	return volume;
}

#endif /* VOLUME_H__ */
