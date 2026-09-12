#ifndef VOLUME_H__
#define VOLUME_H__

/* Volume : attenuation PCM (postmix) + Playback analogique.
 * Mix_VolumeMusic est ignore par le backend MP3 2.0.4 ; le DAC analogique
 * n'enleve pas une saturation deja dans les samples. */

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
/* Analog sous le plafond RK817 (~255 latch/clip). 50% UI un peu plus fort. */
#define R36S_PLAYBACK_MAX 185
#define R36S_PLAYBACK_FLOOR 40
#define R36S_PCM_GAIN_MAX 200 /* /256 ≈ 78 % FS */

static int r36s_spk_ready = 0;
static int r36s_last_hw = -1;
static int r36s_mixer_fd = -1;
static int r36s_playback_numid = -1;
static int r36s_pcm_gain = 90;

static void SDLCALL r36s_postmix(void *udata, Uint8 *stream, int len)
{
	Sint16 *s = (Sint16 *)stream;
	int n = len / 2;
	int i, g, v;

	(void)udata;
	g = r36s_pcm_gain;
	if (g >= 256)
		return;
	for (i = 0; i < n; i++) {
		v = ((int)s[i] * g) >> 8;
		if (v > 32767)
			v = 32767;
		else if (v < -32768)
			v = -32768;
		s[i] = (Sint16)v;
	}
}

static void r36s_ensure_spk_path(void)
{
	char cmd[128];

	if (r36s_spk_ready)
		return;
	snprintf(cmd, sizeof(cmd),
		 "amixer -c 0 -q cset name='Playback Path' %s 2>/dev/null || true",
		 telmi_audio_path());
	system(cmd);
	system("amixer -c 0 -q sset DAC unmute 2>/dev/null || true");
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

/* 50 % UI = ancien 70 % ; le 100 % reste le plafond actuel (anti-latch RK817). */
static int r36s_ui_to_internal(int volume)
{
	int mapped;

	if (volume <= 0)
		return 0;
	if (volume >= 25)
		return 25;
	if (volume <= 13)
		mapped = (volume * 18) / 13;
	else
		mapped = 18 + ((volume - 13) * 7) / 12;
	if (mapped < 1)
		mapped = 1;
	if (mapped > 25)
		mapped = 25;
	return mapped;
}

/* UI 0..25 → Playback analogique FLOOR..MAX (pas 255). */
static int r36s_volume_to_hw(int volume)
{
	int hw;
	int v = r36s_ui_to_internal(volume);

	if (v <= 0)
		return 0;
	hw = R36S_PLAYBACK_FLOOR +
	     (v * (R36S_PLAYBACK_MAX - R36S_PLAYBACK_FLOOR)) / 25;
	if (hw < R36S_PLAYBACK_FLOOR)
		hw = R36S_PLAYBACK_FLOOR;
	if (hw > R36S_PLAYBACK_MAX)
		hw = R36S_PLAYBACK_MAX;
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

	/* Postmix : vrai gain numerique (Mix_VolumeMusic no-op sur MP3 mpg123). */
	if (volume <= 0)
		r36s_pcm_gain = 0;
	else {
		r36s_pcm_gain = (r36s_ui_to_internal(volume) * R36S_PCM_GAIN_MAX) / 25;
		if (r36s_pcm_gain < 8)
			r36s_pcm_gain = 8;
	}
	Mix_SetPostMix(r36s_postmix, NULL);
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
