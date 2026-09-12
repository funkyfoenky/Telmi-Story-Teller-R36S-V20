/**
 * telmi_lr — frontend libretro minimal pour TelmiOS R36S
 * Usage : telmi_lr <core.so> <rom>
 * Video : /dev/fb0  |  Audio : SDL QueueAudio  |  Quit : MENU/FN
 */
#include <dlfcn.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <linux/input.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>

#include <sys/stat.h>
#include <errno.h>
#include <sound/asound.h>

#include <SDL2/SDL.h>

#include "../system/keymap_hw.h"
#include "libretro.h"
#include "controls_map.h"

#define INPUT_MAX 8
#define FB_W 640
#define FB_H 480
#define TELMI_STATE_DIR "/telmi/Saves/states"

struct fb_ctx {
	int fd;
	uint8_t *mem;
	size_t mem_len;
	struct fb_var_screeninfo vinfo;
	struct fb_fix_screeninfo finfo;
	int bpp;
};

static struct {
	void *handle;
	void (*retro_init)(void);
	void (*retro_deinit)(void);
	unsigned (*retro_api_version)(void);
	void (*retro_get_system_info)(struct retro_system_info *);
	void (*retro_get_system_av_info)(struct retro_system_av_info *);
	void (*retro_set_environment)(retro_environment_t);
	void (*retro_set_video_refresh)(retro_video_refresh_t);
	void (*retro_set_audio_sample)(retro_audio_sample_t);
	void (*retro_set_audio_sample_batch)(retro_audio_sample_batch_t);
	void (*retro_set_input_poll)(retro_input_poll_t);
	void (*retro_set_input_state)(retro_input_state_t);
	void (*retro_set_controller_port_device)(unsigned, unsigned);
	void (*retro_reset)(void);
	void (*retro_run)(void);
	bool (*retro_load_game)(const struct retro_game_info *);
	void (*retro_unload_game)(void);
	size_t (*retro_serialize_size)(void);
	bool (*retro_serialize)(void *, size_t);
	bool (*retro_unserialize)(const void *, size_t);
	void *(*retro_get_memory_data)(unsigned);
	size_t (*retro_get_memory_size)(unsigned);
} core;

static struct fb_ctx fb;
static SDL_AudioDeviceID audio_dev;
static int16_t *audio_ring;
static size_t audio_ring_cap;
static size_t audio_ring_len;
static int16_t emu_pcm_tmp[8192];
static unsigned joy[16];
static int input_fds[INPUT_MAX];
static int input_count;
static struct pollfd pfds[INPUT_MAX];
static bool running = true;
static unsigned pixel_fmt = RETRO_PIXEL_FORMAT_0RGB1555;
static unsigned frame_w, frame_h, frame_pitch;
static uint8_t *frame_rgb;
static size_t frame_rgb_cap;
static double target_fps = 60.0;
static double sample_rate = 44100.0;
/* Ratio d'affichage core (ex. PSX 4:3) — pas le ratio pixels bruts */
static float display_aspect = 0.f;
static unsigned last_dst_w, last_dst_h;

/* Options core (PCSX ReARMed frameskip, etc.) */
static bool core_vars_updated = true;
static retro_audio_buffer_status_callback_t audio_buff_status_cb;

static const struct {
	const char *key;
	const char *value;
} telmi_core_opts[] = {
	/* Frameskip auto basé sur buffer audio (nécessite SET_AUDIO_BUFFER_STATUS) */
	{ "pcsx_rearmed_frameskip_type", "auto" },
	{ "pcsx_rearmed_frameskip_threshold", "33" },
	{ "pcsx_rearmed_frameskip_interval", "1" },
	{ NULL, NULL }
};

static const char *telmi_opt_get(const char *key)
{
	unsigned i;

	if (!key)
		return NULL;
	for (i = 0; telmi_core_opts[i].key; i++) {
		if (strcmp(telmi_core_opts[i].key, key) == 0)
			return telmi_core_opts[i].value;
	}
	return NULL;
}

static void notify_audio_buffer_status(void)
{
	Uint32 queued, ideal, one_frame;
	unsigned occ;
	bool underrun;

	if (!audio_buff_status_cb || !audio_dev)
		return;
	queued = SDL_GetQueuedAudioSize(audio_dev);
	/* Occupancy vs ~50 ms cible */
	ideal = (Uint32)(sample_rate * 4.0 * 0.05);
	if (ideal < 2048)
		ideal = 2048;
	occ = (unsigned)((queued * 100u) / ideal);
	if (occ > 100)
		occ = 100;
	one_frame = (Uint32)(sample_rate * 4.0 / target_fps);
	if (one_frame < 256)
		one_frame = 256;
	underrun = queued < one_frame * 2;
	audio_buff_status_cb(true, occ, underrun);
}

/* Volume UI 0..25 (echelle Telmi) — ALSA Playback, comme gbemu */
static int emu_volume = 15;
static int emu_mixer_fd = -1;
static int emu_playback_numid = -1;
static int emu_last_hw = -1;

#define load_sym(V, S) do { \
	*(void **)&(V) = dlsym(core.handle, #S); \
	if (!(V)) { fprintf(stderr, "[telmi_lr] missing %s\n", #S); return -1; } \
} while (0)

static void fb_unblank(void)
{
	int fd = open("/sys/class/graphics/fb0/blank", O_WRONLY);
	if (fd >= 0) {
		write(fd, "0", 1);
		close(fd);
	}
}

static int fb_open(struct fb_ctx *f)
{
	memset(f, 0, sizeof(*f));
	f->fd = open("/dev/fb0", O_RDWR);
	if (f->fd < 0)
		return -1;
	if (ioctl(f->fd, FBIOGET_FSCREENINFO, &f->finfo) ||
	    ioctl(f->fd, FBIOGET_VSCREENINFO, &f->vinfo)) {
		close(f->fd);
		return -1;
	}
	f->bpp = f->vinfo.bits_per_pixel;
	f->mem_len = f->finfo.smem_len;
	f->mem = mmap(NULL, f->mem_len, PROT_READ | PROT_WRITE, MAP_SHARED, f->fd, 0);
	if (f->mem == MAP_FAILED) {
		close(f->fd);
		f->fd = -1;
		return -1;
	}
	return 0;
}

static void fb_close(struct fb_ctx *f)
{
	if (f->mem && f->mem != MAP_FAILED)
		munmap(f->mem, f->mem_len);
	if (f->fd >= 0)
		close(f->fd);
	memset(f, 0, sizeof(*f));
	f->fd = -1;
}

static void open_inputs(void)
{
	char path[64];
	int i, fd;
	input_count = 0;
	for (i = 0; i < 32 && input_count < INPUT_MAX; i++) {
		snprintf(path, sizeof(path), "/dev/input/event%d", i);
		fd = open(path, O_RDONLY | O_NONBLOCK);
		if (fd < 0)
			continue;
		input_fds[input_count] = fd;
		pfds[input_count].fd = fd;
		pfds[input_count].events = POLLIN;
		input_count++;
	}
}

static void close_inputs(void)
{
	int i;
	for (i = 0; i < input_count; i++)
		close(input_fds[i]);
	input_count = 0;
}

static void set_btn(unsigned id, int pressed)
{
	if (id < 16)
		joy[id] = pressed ? 1 : 0;
}

static void emu_mixer_init(void)
{
	struct snd_ctl_elem_list elist;
	struct snd_ctl_elem_id *ids = NULL;
	unsigned int i;

	if (emu_mixer_fd >= 0)
		return;
	emu_mixer_fd = open("/dev/snd/controlC0", O_RDWR);
	if (emu_mixer_fd < 0)
		return;
	memset(&elist, 0, sizeof(elist));
	if (ioctl(emu_mixer_fd, SNDRV_CTL_IOCTL_ELEM_LIST, &elist) < 0)
		return;
	if (elist.count == 0)
		return;
	ids = calloc(elist.count, sizeof(*ids));
	if (!ids)
		return;
	elist.space = elist.count;
	elist.pids = ids;
	if (ioctl(emu_mixer_fd, SNDRV_CTL_IOCTL_ELEM_LIST, &elist) < 0) {
		free(ids);
		return;
	}
	for (i = 0; i < elist.count; i++) {
		if (strcmp((const char *)ids[i].name, "Playback") == 0) {
			emu_playback_numid = (int)ids[i].numid;
			break;
		}
	}
	free(ids);
}

static int emu_ui_to_internal(int volume)
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

static int emu_volume_to_hw(int volume)
{
	int hw;
	int v = emu_ui_to_internal(volume);
	if (v <= 0)
		return 0;
	hw = 40 + (v * (185 - 40)) / 25;
	if (hw < 40)
		hw = 40;
	if (hw > 185)
		hw = 185;
	return hw;
}

static int emu_pcm_gain(void)
{
	int g;
	if (emu_volume <= 0)
		return 0;
	g = (emu_ui_to_internal(emu_volume) * 200) / 25;
	if (g < 8)
		g = 8;
	return g;
}

static void emu_apply_volume(void)
{
	int hw = emu_volume_to_hw(emu_volume);
	struct snd_ctl_elem_value ev;

	if (hw == emu_last_hw)
		return;
	emu_last_hw = hw;

	emu_mixer_init();
	if (emu_mixer_fd < 0 || emu_playback_numid < 0) {
		char cmd[160];
		if (hw <= 0)
			system("amixer -c 0 -q sset Playback 0 mute 2>/dev/null || true");
		else {
			snprintf(cmd, sizeof(cmd),
				 "amixer -c 0 -q sset Playback %d unmute 2>/dev/null || true", hw);
			system(cmd);
		}
		return;
	}
	memset(&ev, 0, sizeof(ev));
	ev.id.numid = (unsigned)emu_playback_numid;
	ev.value.integer.value[0] = hw;
	ev.value.integer.value[1] = hw;
	ioctl(emu_mixer_fd, SNDRV_CTL_IOCTL_ELEM_WRITE, &ev);
}

static void emu_volume_delta(int delta)
{
	emu_volume += delta;
	if (emu_volume < 0)
		emu_volume = 0;
	if (emu_volume > 25)
		emu_volume = 25;
	emu_apply_volume();
	fprintf(stderr, "[telmi_lr] volume %d/25\n", emu_volume);
}

static void handle_key(unsigned code, int pressed)
{
	if (HW_BTN_IS_MENU(code)) {
		if (pressed)
			running = false;
		return;
	}
	if (code == HW_BTN_VOLUME_UP) {
		if (pressed)
			emu_volume_delta(1);
		return;
	}
	if (code == HW_BTN_VOLUME_DOWN) {
		if (pressed)
			emu_volume_delta(-1);
		return;
	}
	controls_apply_hw(code, pressed, set_btn);
}

static void poll_inputs(void)
{
	struct input_event ev;
	int i, n;

	poll(pfds, (nfds_t)input_count, 0);
	for (i = 0; i < input_count; i++) {
		if (!(pfds[i].revents & POLLIN))
			continue;
		while ((n = (int)read(input_fds[i], &ev, sizeof(ev))) == (int)sizeof(ev)) {
			if (ev.type == EV_KEY)
				handle_key(ev.code, ev.value != 0);
			else if (ev.type == EV_ABS) {
				/* D-pad HAT analog sur certains pads */
				if (ev.code == ABS_HAT0X)
					controls_apply_hat_x(ev.value, set_btn);
				else if (ev.code == ABS_HAT0Y)
					controls_apply_hat_y(ev.value, set_btn);
			}
		}
	}
}

static uint32_t pix_to_rgb32(const void *data, unsigned x, unsigned y, unsigned pitch)
{
	const uint8_t *row = (const uint8_t *)data + y * pitch;

	if (pixel_fmt == RETRO_PIXEL_FORMAT_XRGB8888) {
		const uint32_t *p = (const uint32_t *)row;
		return p[x] | 0xFF000000u;
	}
	if (pixel_fmt == RETRO_PIXEL_FORMAT_RGB565) {
		uint16_t p = ((const uint16_t *)row)[x];
		unsigned r = (p >> 11) & 0x1F;
		unsigned g = (p >> 5) & 0x3F;
		unsigned b = p & 0x1F;
		r = (r << 3) | (r >> 2);
		g = (g << 2) | (g >> 4);
		b = (b << 3) | (b >> 2);
		return 0xFF000000u | (r << 16) | (g << 8) | b;
	}
	/* 0RGB1555 */
	{
		uint16_t p = ((const uint16_t *)row)[x];
		unsigned r = (p >> 10) & 0x1F;
		unsigned g = (p >> 5) & 0x1F;
		unsigned b = p & 0x1F;
		r = (r << 3) | (r >> 2);
		g = (g << 3) | (g >> 2);
		b = (b << 3) | (b >> 2);
		return 0xFF000000u | (r << 16) | (g << 8) | b;
	}
}

static void blit_frame(const void *data, unsigned width, unsigned height, size_t pitch)
{
	unsigned sw, sh, x0, y0, x, y, scale;
	float aspect;
	int exact_scale;
	const uint8_t *src = data;

	if (!data || !fb.mem || width == 0 || height == 0)
		return;

	/*
	 * PSX est 4:3 : sur 640x480 on remplit l'écran via display_aspect.
	 * Attention : le framebuffer core n'est pas toujours 320x240
	 * (souvent 512x240, etc.) — le ratio pixels != 4:3.
	 * Scale entier rapide seulement s'il tombe pile sur ce rectangle 4:3
	 * (ex. 320x240 → 640x480 = 2x exact).
	 */
	aspect = display_aspect;
	if (aspect <= 0.01f)
		aspect = (float)width / (float)height;

	if ((float)FB_W / aspect <= (float)FB_H) {
		sw = FB_W;
		sh = (unsigned)((float)FB_W / aspect + 0.5f);
	} else {
		sh = FB_H;
		sw = (unsigned)((float)FB_H * aspect + 0.5f);
	}
	if (sw < 1)
		sw = 1;
	if (sh < 1)
		sh = 1;
	if (sw > FB_W)
		sw = FB_W;
	if (sh > FB_H)
		sh = FB_H;
	x0 = (FB_W - sw) / 2;
	y0 = (FB_H - sh) / 2;

	exact_scale = 0;
	scale = 1;
	if (sw % width == 0 && sh % height == 0 && (sw / width) == (sh / height)) {
		scale = sw / width;
		exact_scale = (scale >= 1 && scale <= 4);
	}

	if (sw != last_dst_w || sh != last_dst_h) {
		memset(fb.mem, 0, fb.mem_len);
		last_dst_w = sw;
		last_dst_h = sh;
	}

	/* Fast path : scale entier exact (typ. 320x240 → 640x480) */
	if (exact_scale && pixel_fmt == RETRO_PIXEL_FORMAT_RGB565 && fb.bpp == 16 && scale == 1) {
		for (y = 0; y < height; y++) {
			const uint16_t *srow = (const uint16_t *)(src + y * pitch);
			uint16_t *drow = (uint16_t *)(fb.mem + (y0 + y) * fb.finfo.line_length + x0 * 2);
			memcpy(drow, srow, width * 2);
		}
		return;
	}
	if (exact_scale && pixel_fmt == RETRO_PIXEL_FORMAT_RGB565 && fb.bpp == 16 && scale == 2) {
		for (y = 0; y < height; y++) {
			const uint16_t *srow = (const uint16_t *)(src + y * pitch);
			uint16_t *d0 = (uint16_t *)(fb.mem + (y0 + y * 2) * fb.finfo.line_length + x0 * 2);
			uint16_t *d1 = (uint16_t *)(fb.mem + (y0 + y * 2 + 1) * fb.finfo.line_length + x0 * 2);
			for (x = 0; x < width; x++) {
				uint16_t c = srow[x];
				d0[x * 2] = c;
				d0[x * 2 + 1] = c;
				d1[x * 2] = c;
				d1[x * 2 + 1] = c;
			}
		}
		return;
	}
	if (exact_scale && pixel_fmt == RETRO_PIXEL_FORMAT_RGB565 && fb.bpp == 32 &&
	    (scale == 1 || scale == 2)) {
		for (y = 0; y < height; y++) {
			const uint16_t *srow = (const uint16_t *)(src + y * pitch);
			uint32_t *d0 = (uint32_t *)(fb.mem + (y0 + y * scale) * fb.finfo.line_length + x0 * 4);
			uint32_t *d1 = (scale == 2)
				? (uint32_t *)(fb.mem + (y0 + y * 2 + 1) * fb.finfo.line_length + x0 * 4)
				: NULL;
			for (x = 0; x < width; x++) {
				uint16_t p = srow[x];
				unsigned r = (p >> 11) & 0x1F;
				unsigned g = (p >> 5) & 0x3F;
				unsigned b = p & 0x1F;
				uint32_t c = 0xFF000000u |
					((r << 3) | (r >> 2)) << 16 |
					((g << 2) | (g >> 4)) << 8 |
					((b << 3) | (b >> 2));
				if (scale == 1) {
					d0[x] = c;
				} else {
					d0[x * 2] = c;
					d0[x * 2 + 1] = c;
					d1[x * 2] = c;
					d1[x * 2 + 1] = c;
				}
			}
		}
		return;
	}
	if (exact_scale && pixel_fmt == RETRO_PIXEL_FORMAT_XRGB8888 && fb.bpp == 32 && scale == 1) {
		for (y = 0; y < height; y++) {
			const uint32_t *srow = (const uint32_t *)(src + y * pitch);
			uint32_t *drow = (uint32_t *)(fb.mem + (y0 + y) * fb.finfo.line_length + x0 * 4);
			for (x = 0; x < width; x++)
				drow[x] = srow[x] | 0xFF000000u;
		}
		return;
	}
	if (exact_scale && pixel_fmt == RETRO_PIXEL_FORMAT_XRGB8888 && fb.bpp == 32 && scale == 2) {
		for (y = 0; y < height; y++) {
			const uint32_t *srow = (const uint32_t *)(src + y * pitch);
			uint32_t *d0 = (uint32_t *)(fb.mem + (y0 + y * 2) * fb.finfo.line_length + x0 * 4);
			uint32_t *d1 = (uint32_t *)(fb.mem + (y0 + y * 2 + 1) * fb.finfo.line_length + x0 * 4);
			for (x = 0; x < width; x++) {
				uint32_t c = srow[x] | 0xFF000000u;
				d0[x * 2] = c;
				d0[x * 2 + 1] = c;
				d1[x * 2] = c;
				d1[x * 2 + 1] = c;
			}
		}
		return;
	}

	/* Stretch nearest vers le rectangle 4:3 (plein écran sur 640x480) */
	for (y = 0; y < sh; y++) {
		unsigned syi = (y * height) / sh;
		for (x = 0; x < sw; x++) {
			unsigned sxi = (x * width) / sw;
			uint32_t c = pix_to_rgb32(data, sxi, syi, (unsigned)pitch);
			unsigned dx = x0 + x;
			unsigned dy = y0 + y;
			size_t off = dy * fb.finfo.line_length + dx * (fb.bpp / 8);

			if (fb.bpp == 32) {
				uint32_t *p = (uint32_t *)(fb.mem + off);
				*p = c;
			} else if (fb.bpp == 16) {
				uint16_t *p = (uint16_t *)(fb.mem + off);
				unsigned r = (c >> 19) & 0x1F;
				unsigned g = (c >> 10) & 0x3F;
				unsigned b = (c >> 3) & 0x1F;
				*p = (uint16_t)((r << 11) | (g << 5) | b);
			}
		}
	}
}

static void video_refresh(const void *data, unsigned width, unsigned height, size_t pitch)
{
	if (!data)
		return;
	frame_w = width;
	frame_h = height;
	frame_pitch = (unsigned)pitch;
	blit_frame(data, width, height, pitch);
}

static void audio_sample(int16_t left, int16_t right)
{
	int16_t in[2] = { left, right };
	int16_t s[2];
	int g, i, v;

	if (!audio_dev)
		return;
	g = emu_pcm_gain();
	for (i = 0; i < 2; i++) {
		v = ((int)in[i] * g) >> 8;
		if (v > 32767)
			v = 32767;
		else if (v < -32768)
			v = -32768;
		s[i] = (int16_t)v;
	}
	SDL_QueueAudio(audio_dev, s, sizeof(s));
}

static size_t audio_sample_batch(const int16_t *data, size_t frames)
{
	size_t done = 0;
	int g, i, v;
	size_t n, ns;

	if (!audio_dev || !data || !frames)
		return frames;
	g = emu_pcm_gain();
	while (done < frames) {
		n = frames - done;
		if (n > 4096)
			n = 4096;
		ns = n * 2;
		for (i = 0; i < (int)ns; i++) {
			v = ((int)data[done * 2 + i] * g) >> 8;
			if (v > 32767)
				v = 32767;
			else if (v < -32768)
				v = -32768;
			emu_pcm_tmp[i] = (int16_t)v;
		}
		SDL_QueueAudio(audio_dev, emu_pcm_tmp, (Uint32)(n * 4));
		done += n;
	}
	return frames;
}

static void input_poll(void)
{
	poll_inputs();
}

static int16_t input_state(unsigned port, unsigned device, unsigned index, unsigned id)
{
	(void)index;
	if (port != 0 || device != RETRO_DEVICE_JOYPAD)
		return 0;
	if (id < 16)
		return (int16_t)joy[id];
	return 0;
}

static void apply_geometry(const struct retro_game_geometry *geom)
{
	if (!geom)
		return;
	if (geom->aspect_ratio > 0.01f)
		display_aspect = geom->aspect_ratio;
	else if (geom->base_width > 0 && geom->base_height > 0)
		display_aspect = (float)geom->base_width / (float)geom->base_height;
}

static bool env_cb(unsigned cmd, void *data)
{
	switch (cmd) {
	case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: {
		enum retro_pixel_format *fmt = data;
		if (*fmt == RETRO_PIXEL_FORMAT_XRGB8888 ||
		    *fmt == RETRO_PIXEL_FORMAT_RGB565 ||
		    *fmt == RETRO_PIXEL_FORMAT_0RGB1555) {
			pixel_fmt = *fmt;
			return true;
		}
		return false;
	}
	case RETRO_ENVIRONMENT_GET_CAN_DUPE:
		*(bool *)data = true;
		return true;
	case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
	case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY: {
		static const char *dir = "/telmi/Saves";
		*(const char **)data = dir;
		return true;
	}
	case RETRO_ENVIRONMENT_SET_GEOMETRY:
		apply_geometry((const struct retro_game_geometry *)data);
		return true;
	case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO:
		if (data) {
			const struct retro_system_av_info *av = data;
			apply_geometry(&av->geometry);
			if (av->timing.fps > 1.0)
				target_fps = av->timing.fps;
			if (av->timing.sample_rate > 1.0)
				sample_rate = av->timing.sample_rate;
		}
		return true;
	case RETRO_ENVIRONMENT_GET_VARIABLE: {
		struct retro_variable *var = data;
		const char *val;

		if (!var || !var->key)
			return false;
		val = telmi_opt_get(var->key);
		if (!val) {
			var->value = NULL;
			return false;
		}
		var->value = val;
		return true;
	}
	case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
		if (data) {
			*(bool *)data = core_vars_updated;
			core_vars_updated = false;
		}
		return true;
	case RETRO_ENVIRONMENT_SET_VARIABLES:
	case RETRO_ENVIRONMENT_SET_CORE_OPTIONS:
	case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_INTL:
	case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2:
	case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL:
		return true;
	case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION:
		*(unsigned *)data = 2;
		return true;
	case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY:
		return true;
	case RETRO_ENVIRONMENT_SET_AUDIO_BUFFER_STATUS_CALLBACK: {
		const struct retro_audio_buffer_status_callback *cb = data;

		audio_buff_status_cb = (cb && cb->callback) ? cb->callback : NULL;
		return true;
	}
	case RETRO_ENVIRONMENT_SET_MINIMUM_AUDIO_LATENCY:
		return true;
	case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
		return false;
	case RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME:
		return true;
	default:
		return false;
	}
}

static int load_core(const char *path)
{
	core.handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL);
	if (!core.handle) {
		fprintf(stderr, "[telmi_lr] dlopen %s: %s\n", path, dlerror());
		return -1;
	}
	load_sym(core.retro_init, retro_init);
	load_sym(core.retro_deinit, retro_deinit);
	load_sym(core.retro_api_version, retro_api_version);
	load_sym(core.retro_get_system_info, retro_get_system_info);
	load_sym(core.retro_get_system_av_info, retro_get_system_av_info);
	load_sym(core.retro_set_environment, retro_set_environment);
	load_sym(core.retro_set_video_refresh, retro_set_video_refresh);
	load_sym(core.retro_set_audio_sample, retro_set_audio_sample);
	load_sym(core.retro_set_audio_sample_batch, retro_set_audio_sample_batch);
	load_sym(core.retro_set_input_poll, retro_set_input_poll);
	load_sym(core.retro_set_input_state, retro_set_input_state);
	load_sym(core.retro_set_controller_port_device, retro_set_controller_port_device);
	load_sym(core.retro_reset, retro_reset);
	load_sym(core.retro_run, retro_run);
	load_sym(core.retro_load_game, retro_load_game);
	load_sym(core.retro_unload_game, retro_unload_game);
	/* Optionnels (savestate / SRAM) */
	*(void **)&core.retro_serialize_size = dlsym(core.handle, "retro_serialize_size");
	*(void **)&core.retro_serialize = dlsym(core.handle, "retro_serialize");
	*(void **)&core.retro_unserialize = dlsym(core.handle, "retro_unserialize");
	*(void **)&core.retro_get_memory_data = dlsym(core.handle, "retro_get_memory_data");
	*(void **)&core.retro_get_memory_size = dlsym(core.handle, "retro_get_memory_size");
	return 0;
}

static void state_paths_from_rom(const char *rom_path, char *state_path, size_t state_sz,
				 char *sav_path, size_t sav_sz)
{
	const char *base;
	char name[256];
	char *dot;

	base = strrchr(rom_path, '/');
	base = base ? base + 1 : rom_path;
	snprintf(name, sizeof(name), "%s", base);
	dot = strrchr(name, '.');
	if (dot)
		*dot = '\0';
	mkdir("/telmi", 0755);
	mkdir("/telmi/Saves", 0755);
	mkdir(TELMI_STATE_DIR, 0755);
	snprintf(state_path, state_sz, "%s/%s.state", TELMI_STATE_DIR, name);
	snprintf(sav_path, sav_sz, "%s/%s.sav", TELMI_STATE_DIR, name);
}

static int write_blob(const char *path, const void *data, size_t len)
{
	FILE *f;

	if (!data || len == 0)
		return -1;
	f = fopen(path, "wb");
	if (!f)
		return -1;
	if (fwrite(data, 1, len, f) != len) {
		fclose(f);
		return -1;
	}
	fclose(f);
	return 0;
}

static void *read_blob(const char *path, size_t *out_len)
{
	FILE *f = fopen(path, "rb");
	uint8_t *buf;
	long sz;

	if (!f)
		return NULL;
	fseek(f, 0, SEEK_END);
	sz = ftell(f);
	fseek(f, 0, SEEK_SET);
	if (sz <= 0) {
		fclose(f);
		return NULL;
	}
	buf = malloc((size_t)sz);
	if (!buf) {
		fclose(f);
		return NULL;
	}
	if (fread(buf, 1, (size_t)sz, f) != (size_t)sz) {
		free(buf);
		fclose(f);
		return NULL;
	}
	fclose(f);
	*out_len = (size_t)sz;
	return buf;
}

static void save_state_and_sram(const char *rom_path)
{
	char state_path[512], sav_path[512];
	void *buf;
	size_t sz;
	void *sram;
	size_t sram_sz;

	state_paths_from_rom(rom_path, state_path, sizeof(state_path), sav_path, sizeof(sav_path));

	if (core.retro_serialize_size && core.retro_serialize) {
		sz = core.retro_serialize_size();
		if (sz > 0) {
			buf = malloc(sz);
			if (buf) {
				if (core.retro_serialize(buf, sz)) {
					if (write_blob(state_path, buf, sz) == 0)
						fprintf(stderr, "[telmi_lr] state saved %s (%zu)\n",
							state_path, sz);
					else
						fprintf(stderr, "[telmi_lr] state write fail %s\n",
							state_path);
				} else {
					fprintf(stderr, "[telmi_lr] retro_serialize failed\n");
				}
				free(buf);
			}
		}
	}

	if (core.retro_get_memory_data && core.retro_get_memory_size) {
		sram = core.retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
		sram_sz = core.retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
		if (sram && sram_sz > 0) {
			if (write_blob(sav_path, sram, sram_sz) == 0)
				fprintf(stderr, "[telmi_lr] sram saved %s (%zu)\n", sav_path, sram_sz);
		}
	}
}

static void load_state_and_sram(const char *rom_path)
{
	char state_path[512], sav_path[512];
	void *buf;
	size_t sz;
	void *sram;
	size_t sram_sz;

	state_paths_from_rom(rom_path, state_path, sizeof(state_path), sav_path, sizeof(sav_path));

	if (core.retro_get_memory_data && core.retro_get_memory_size) {
		sram = core.retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
		sram_sz = core.retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
		if (sram && sram_sz > 0) {
			buf = read_blob(sav_path, &sz);
			if (buf) {
				if (sz == sram_sz) {
					memcpy(sram, buf, sram_sz);
					fprintf(stderr, "[telmi_lr] sram loaded %s\n", sav_path);
				} else {
					fprintf(stderr, "[telmi_lr] sram size mismatch %zu!=%zu\n",
						sz, sram_sz);
				}
				free(buf);
			}
		}
	}

	if (core.retro_serialize_size && core.retro_unserialize) {
		buf = read_blob(state_path, &sz);
		if (buf) {
			if (core.retro_unserialize(buf, sz))
				fprintf(stderr, "[telmi_lr] state loaded %s\n", state_path);
			else
				fprintf(stderr, "[telmi_lr] state load failed %s\n", state_path);
			free(buf);
		}
	}
}

static uint8_t *load_file(const char *path, size_t *out_len)
{
	FILE *f = fopen(path, "rb");
	uint8_t *buf;
	long sz;

	if (!f)
		return NULL;
	fseek(f, 0, SEEK_END);
	sz = ftell(f);
	fseek(f, 0, SEEK_SET);
	if (sz <= 0) {
		fclose(f);
		return NULL;
	}
	buf = malloc((size_t)sz);
	if (!buf) {
		fclose(f);
		return NULL;
	}
	if (fread(buf, 1, (size_t)sz, f) != (size_t)sz) {
		free(buf);
		fclose(f);
		return NULL;
	}
	fclose(f);
	*out_len = (size_t)sz;
	return buf;
}

static int init_audio(int rate)
{
	SDL_AudioSpec want, have;

	if (SDL_Init(SDL_INIT_AUDIO) != 0) {
		fprintf(stderr, "[telmi_lr] SDL_Init: %s\n", SDL_GetError());
		return -1;
	}
	memset(&want, 0, sizeof(want));
	want.freq = rate;
	want.format = AUDIO_S16SYS;
	want.channels = 2;
	want.samples = 1024;
	audio_dev = SDL_OpenAudioDevice(NULL, 0, &want, &have, 0);
	if (!audio_dev) {
		fprintf(stderr, "[telmi_lr] OpenAudio: %s\n", SDL_GetError());
		return -1;
	}
	SDL_PauseAudioDevice(audio_dev, 0);
	return 0;
}

int main(int argc, char **argv)
{
	struct retro_system_info sysinfo;
	struct retro_system_av_info av;
	struct retro_game_info game;
	uint8_t *rom = NULL;
	size_t rom_len = 0;
	struct timespec next;
	long frame_ns;
	const char *core_path;
	const char *rom_path;
	const char *console_id = NULL;

	if (argc < 3) {
		fprintf(stderr, "usage: %s <core.so> <rom> [console_id]\n", argv[0]);
		return 1;
	}
	core_path = argv[1];
	rom_path = argv[2];
	if (argc >= 4 && argv[3] && argv[3][0])
		console_id = argv[3];
	else {
		/* Infer from /telmi/Games/<sys>/... */
		const char *p = strstr(rom_path, "/Games/");
		if (p) {
			static char inferred[16];
			size_t i = 0;
			p += 7;
			while (p[i] && p[i] != '/' && i < sizeof(inferred) - 1) {
				inferred[i] = p[i];
				i++;
			}
			inferred[i] = 0;
			if (inferred[0])
				console_id = inferred;
		}
	}

	controls_init(console_id);

	if (load_core(core_path) != 0)
		return 1;

	core.retro_set_environment(env_cb);
	core.retro_init();
	core.retro_set_video_refresh(video_refresh);
	core.retro_set_audio_sample(audio_sample);
	core.retro_set_audio_sample_batch(audio_sample_batch);
	core.retro_set_input_poll(input_poll);
	core.retro_set_input_state(input_state);

	memset(&sysinfo, 0, sizeof(sysinfo));
	core.retro_get_system_info(&sysinfo);
	fprintf(stderr, "[telmi_lr] core=%s need_fullpath=%d\n",
		sysinfo.library_name ? sysinfo.library_name : "?",
		sysinfo.need_fullpath ? 1 : 0);

	memset(&game, 0, sizeof(game));
	game.path = rom_path;
	if (!sysinfo.need_fullpath) {
		rom = load_file(rom_path, &rom_len);
		if (!rom) {
			fprintf(stderr, "[telmi_lr] cannot read %s\n", rom_path);
			return 1;
		}
		game.data = rom;
		game.size = rom_len;
	}

	if (!core.retro_load_game(&game)) {
		fprintf(stderr, "[telmi_lr] load_game failed\n");
		free(rom);
		return 1;
	}
	load_state_and_sram(rom_path);

	core.retro_get_system_av_info(&av);
	target_fps = av.timing.fps > 1.0 ? av.timing.fps : 60.0;
	sample_rate = av.timing.sample_rate > 1.0 ? av.timing.sample_rate : 44100.0;
	apply_geometry(&av.geometry);
	fprintf(stderr, "[telmi_lr] aspect=%.4f geom=%ux%u fps=%.2f\n",
		display_aspect, av.geometry.base_width, av.geometry.base_height, target_fps);
	frame_ns = (long)(1e9 / target_fps);

	fb_unblank();
	if (fb_open(&fb) != 0) {
		fprintf(stderr, "[telmi_lr] cannot open fb0\n");
		core.retro_unload_game();
		core.retro_deinit();
		free(rom);
		return 1;
	}
	memset(fb.mem, 0, fb.mem_len);

	open_inputs();
	init_audio((int)sample_rate);
	emu_apply_volume();
	core.retro_set_controller_port_device(0, RETRO_DEVICE_JOYPAD);

	fprintf(stderr, "[telmi_lr] %s — VOL+/- volume, MENU/FN quit (+save state)\n", rom_path);
	clock_gettime(CLOCK_MONOTONIC, &next);

	while (running) {
		struct timespec now;

		notify_audio_buffer_status();
		core.retro_run();

		next.tv_nsec += frame_ns;
		while (next.tv_nsec >= 1000000000L) {
			next.tv_nsec -= 1000000000L;
			next.tv_sec++;
		}
		clock_gettime(CLOCK_MONOTONIC, &now);
		if (now.tv_sec < next.tv_sec ||
		    (now.tv_sec == next.tv_sec && now.tv_nsec < next.tv_nsec)) {
			struct timespec rem = {
				.tv_sec = next.tv_sec - now.tv_sec,
				.tv_nsec = next.tv_nsec - now.tv_nsec
			};
			if (rem.tv_nsec < 0) {
				rem.tv_nsec += 1000000000L;
				rem.tv_sec--;
			}
			nanosleep(&rem, NULL);
		} else {
			next = now;
		}

		/* Limite douce (~150 ms) pour éviter saturation audio sans bloquer trop */
		if (audio_dev) {
			Uint32 limit = (Uint32)(sample_rate * 4.0 * 0.15);
			while (SDL_GetQueuedAudioSize(audio_dev) > limit)
				SDL_Delay(1);
		}
	}

	save_state_and_sram(rom_path);

	if (audio_dev)
		SDL_CloseAudioDevice(audio_dev);
	SDL_Quit();
	close_inputs();
	fb_close(&fb);
	core.retro_unload_game();
	core.retro_deinit();
	dlclose(core.handle);
	free(rom);
	free(frame_rgb);
	free(audio_ring);
	(void)audio_ring_cap;
	(void)audio_ring_len;
	(void)frame_rgb_cap;
	(void)frame_w;
	(void)frame_h;
	(void)frame_pitch;
	return 0;
}
