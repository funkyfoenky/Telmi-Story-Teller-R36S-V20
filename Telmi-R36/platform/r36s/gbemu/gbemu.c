/**
 * gbemu — Peanut-GB + minigb_apu pour TelmiOS R36S
 * Vidéo : /dev/fb0 (fluide). Audio : SDL QueueAudio sync frames.
 * Quitter : MENU/FN
 */
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
#include <sound/asound.h>

#include <sys/stat.h>

#include <SDL2/SDL.h>

#include "../system/keymap_hw.h"

#define ENABLE_SOUND 1
#define ENABLE_LCD 1
#define PEANUT_GB_HIGH_LCD_ACCURACY 0
#define PEANUT_GB_12_COLOUR 0
#define MINIGB_APU_AUDIO_FORMAT_S16SYS
#ifndef AUDIO_SAMPLE_RATE
# define AUDIO_SAMPLE_RATE 22050
#endif

#include "minigb_apu.h"

uint8_t audio_read(uint16_t addr);
void audio_write(uint16_t addr, uint8_t val);

#include "peanut_gb.h"

#define INPUT_MAX 8
#define SCALE 3
#define SCALED_W (LCD_WIDTH * SCALE)
#define SCALED_H (LCD_HEIGHT * SCALE)
#define FRAME_NS 16742706L
#define TELMI_STATE_DIR "/telmi/Saves/states"
#define GB_STATE_MAGIC "TELMI_GB1"

struct priv_t {
	uint8_t *rom;
	uint8_t *cart_ram;
	size_t save_size;
	uint8_t fb[LCD_HEIGHT][LCD_WIDTH];
};

struct fb_ctx {
	int fd;
	uint8_t *mem;
	size_t mem_len;
	struct fb_var_screeninfo vinfo;
	struct fb_fix_screeninfo finfo;
	int x0;
	int y0;
	int bpp;
};

static const uint32_t palette32[4] = {
	0x00F8F0B0u, 0x00B0A868u, 0x00605030u, 0x00201810u
};
static const uint16_t palette16[4] = {
	0x8F7B, 0x5AD5, 0x3208, 0x1082
};

static int input_fds[INPUT_MAX];
static int input_count;
static struct pollfd pfds[INPUT_MAX];
static struct minigb_apu_ctx apu;
static SDL_AudioDeviceID audio_dev;
static audio_sample_t audio_buf[AUDIO_SAMPLES_TOTAL];
/* Volume UI 0..25 (meme echelle Telmi) — applique ALSA Playback */
static int emu_volume = 15;
static int emu_mixer_fd = -1;
static int emu_playback_numid = -1;
static int emu_last_hw = -1;

static void emu_volume_delta(int delta);

uint8_t audio_read(uint16_t addr)
{
	return minigb_apu_audio_read(&apu, addr);
}

void audio_write(uint16_t addr, uint8_t val)
{
	minigb_apu_audio_write(&apu, addr, val);
}

static uint8_t gb_rom_read(struct gb_s *gb, const uint_fast32_t addr)
{
	struct priv_t *p = (struct priv_t *)gb->direct.priv;
	return p->rom[addr];
}

static uint8_t gb_cart_ram_read(struct gb_s *gb, const uint_fast32_t addr)
{
	struct priv_t *p = (struct priv_t *)gb->direct.priv;
	if (!p->cart_ram || addr >= p->save_size)
		return 0xFF;
	return p->cart_ram[addr];
}

static void gb_cart_ram_write(struct gb_s *gb, const uint_fast32_t addr, const uint8_t val)
{
	struct priv_t *p = (struct priv_t *)gb->direct.priv;
	if (!p->cart_ram || addr >= p->save_size)
		return;
	p->cart_ram[addr] = val;
}

static void gb_error(struct gb_s *gb, const enum gb_error_e err, const uint16_t addr)
{
	(void)gb;
	fprintf(stderr, "[gbemu] error %d @ 0x%04x\n", (int)err, (unsigned)addr);
}

static void lcd_draw_line(struct gb_s *gb, const uint8_t *pixels, const uint_fast8_t line)
{
	struct priv_t *p = (struct priv_t *)gb->direct.priv;
	memcpy(p->fb[line], pixels, LCD_WIDTH);
}

static void fb_unblank(void)
{
	int fd = open("/sys/class/graphics/fb0/blank", O_WRONLY);
	if (fd >= 0) {
		write(fd, "0", 1);
		close(fd);
	}
}

static int fb_open(struct fb_ctx *fb)
{
	memset(fb, 0, sizeof(*fb));
	fb->fd = open("/dev/fb0", O_RDWR);
	if (fb->fd < 0)
		return -1;
	if (ioctl(fb->fd, FBIOGET_FSCREENINFO, &fb->finfo) ||
	    ioctl(fb->fd, FBIOGET_VSCREENINFO, &fb->vinfo)) {
		close(fb->fd);
		fb->fd = -1;
		return -1;
	}
	fb->mem_len = fb->finfo.smem_len;
	fb->mem = mmap(NULL, fb->mem_len, PROT_READ | PROT_WRITE, MAP_SHARED, fb->fd, 0);
	if (fb->mem == MAP_FAILED) {
		close(fb->fd);
		fb->fd = -1;
		fb->mem = NULL;
		return -1;
	}
	fb->bpp = fb->vinfo.bits_per_pixel;
	fb->x0 = ((int)fb->vinfo.xres - SCALED_W) / 2;
	fb->y0 = ((int)fb->vinfo.yres - SCALED_H) / 2;
	if (fb->x0 < 0)
		fb->x0 = 0;
	if (fb->y0 < 0)
		fb->y0 = 0;
	memset(fb->mem, 0, fb->mem_len);
	fprintf(stderr, "[gbemu] fb0 %dx%d bpp=%d\n",
		fb->vinfo.xres, fb->vinfo.yres, fb->bpp);
	return 0;
}

static void fb_close(struct fb_ctx *fb)
{
	if (fb->mem && fb->mem != MAP_FAILED)
		munmap(fb->mem, fb->mem_len);
	if (fb->fd >= 0)
		close(fb->fd);
	fb->mem = NULL;
	fb->fd = -1;
}

static void present_fb(struct fb_ctx *fb, struct priv_t *p)
{
	int y, x, sy;
	uint32_t line_len = fb->finfo.line_length;

	if (fb->bpp == 32 || fb->bpp == 24) {
		for (y = 0; y < LCD_HEIGHT; y++) {
			for (sy = 0; sy < SCALE; sy++) {
				uint32_t *dst = (uint32_t *)(fb->mem +
					(size_t)(fb->y0 + y * SCALE + sy) * line_len) + fb->x0;
				const uint8_t *src = p->fb[y];
				for (x = 0; x < LCD_WIDTH; x++) {
					uint32_t c = palette32[src[x] & 3];
					dst[0] = c;
					dst[1] = c;
					dst[2] = c;
					dst += 3;
				}
			}
		}
	} else {
		for (y = 0; y < LCD_HEIGHT; y++) {
			for (sy = 0; sy < SCALE; sy++) {
				uint16_t *dst = (uint16_t *)(fb->mem +
					(size_t)(fb->y0 + y * SCALE + sy) * line_len) + fb->x0;
				const uint8_t *src = p->fb[y];
				for (x = 0; x < LCD_WIDTH; x++) {
					uint16_t c = palette16[src[x] & 3];
					dst[0] = c;
					dst[1] = c;
					dst[2] = c;
					dst += 3;
				}
			}
		}
	}
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

static void apply_btn(struct gb_s *gb, unsigned code, int pressed)
{
	uint8_t mask = 0;

	/* R36S Nintendo-like : A = East (droite), B = South (bas). */
	if (code == HW_BTN_A)
		mask = JOYPAD_A;
	else if (code == HW_BTN_B)
		mask = JOYPAD_B;
	else if (HW_BTN_IS_SELECT(code))
		mask = JOYPAD_SELECT;
	else if (HW_BTN_IS_START(code))
		mask = JOYPAD_START;
	else if (code == HW_BTN_UP)
		mask = JOYPAD_UP;
	else if (code == HW_BTN_DOWN)
		mask = JOYPAD_DOWN;
	else if (code == HW_BTN_LEFT)
		mask = JOYPAD_LEFT;
	else if (code == HW_BTN_RIGHT)
		mask = JOYPAD_RIGHT;
	else
		return;

	if (pressed)
		gb->direct.joypad &= ~mask;
	else
		gb->direct.joypad |= mask;
}

static int poll_inputs(struct gb_s *gb)
{
	struct input_event ev;
	int i, n;
	static int hat_x, hat_y;

	if (input_count <= 0)
		return 0;
	n = poll(pfds, (nfds_t)input_count, 0);
	if (n <= 0)
		return 0;

	for (i = 0; i < input_count; i++) {
		if (!(pfds[i].revents & POLLIN))
			continue;
		while (read(input_fds[i], &ev, sizeof(ev)) == (ssize_t)sizeof(ev)) {
			if (ev.type == EV_KEY) {
				if (HW_BTN_IS_MENU(ev.code) && ev.value)
					return 1;
				if (ev.code == HW_BTN_VOLUME_UP && ev.value) {
					emu_volume_delta(1);
					continue;
				}
				if (ev.code == HW_BTN_VOLUME_DOWN && ev.value) {
					emu_volume_delta(-1);
					continue;
				}
				if (ev.value == 0 || ev.value == 1)
					apply_btn(gb, ev.code, ev.value == 1);
			} else if (ev.type == EV_ABS) {
				int code = -1, pressed = 0;
				if (ev.code == ABS_HAT0X) {
					if (hat_x < 0)
						apply_btn(gb, HW_BTN_LEFT, 0);
					if (hat_x > 0)
						apply_btn(gb, HW_BTN_RIGHT, 0);
					hat_x = ev.value;
					if (hat_x < 0) {
						code = HW_BTN_LEFT;
						pressed = 1;
					} else if (hat_x > 0) {
						code = HW_BTN_RIGHT;
						pressed = 1;
					}
				} else if (ev.code == ABS_HAT0Y) {
					if (hat_y < 0)
						apply_btn(gb, HW_BTN_UP, 0);
					if (hat_y > 0)
						apply_btn(gb, HW_BTN_DOWN, 0);
					hat_y = ev.value;
					if (hat_y < 0) {
						code = HW_BTN_UP;
						pressed = 1;
					} else if (hat_y > 0) {
						code = HW_BTN_DOWN;
						pressed = 1;
					}
				}
				if (code >= 0)
					apply_btn(gb, (unsigned)code, pressed);
			}
		}
	}
	return 0;
}

static uint8_t *load_file(const char *path, size_t *out_len)
{
	FILE *f;
	uint8_t *buf;
	long sz;

	f = fopen(path, "rb");
	if (!f)
		return NULL;
	fseek(f, 0, SEEK_END);
	sz = ftell(f);
	fseek(f, 0, SEEK_SET);
	if (sz <= 0) {
		fclose(f);
		return NULL;
	}
	buf = (uint8_t *)malloc((size_t)sz);
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

static void gb_state_paths(const char *rom_path, char *state_path, size_t state_sz,
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

static void gb_save_sram(struct priv_t *priv, const char *sav_path)
{
	FILE *f;

	if (!priv->cart_ram || priv->save_size == 0)
		return;
	f = fopen(sav_path, "wb");
	if (!f)
		return;
	fwrite(priv->cart_ram, 1, priv->save_size, f);
	fclose(f);
	fprintf(stderr, "[gbemu] sram saved %s (%zu)\n", sav_path, priv->save_size);
}

static void gb_load_sram(struct priv_t *priv, const char *sav_path)
{
	FILE *f;
	size_t n;

	if (!priv->cart_ram || priv->save_size == 0)
		return;
	f = fopen(sav_path, "rb");
	if (!f)
		return;
	n = fread(priv->cart_ram, 1, priv->save_size, f);
	fclose(f);
	if (n > 0)
		fprintf(stderr, "[gbemu] sram loaded %s (%zu)\n", sav_path, n);
}

static void gb_save_state(struct gb_s *gb, struct priv_t *priv, const char *rom_path)
{
	char state_path[512], sav_path[512];
	FILE *f;
	struct gb_s tmp;
	uint32_t gbsz, apusz, ramsz;

	gb_state_paths(rom_path, state_path, sizeof(state_path), sav_path, sizeof(sav_path));
	gb_save_sram(priv, sav_path);

	tmp = *gb;
	tmp.gb_rom_read = NULL;
	tmp.gb_cart_ram_read = NULL;
	tmp.gb_cart_ram_write = NULL;
	tmp.gb_error = NULL;
	tmp.gb_serial_tx = NULL;
	tmp.gb_serial_rx = NULL;
	tmp.gb_bootrom_read = NULL;
	tmp.display.lcd_draw_line = NULL;
	tmp.direct.priv = NULL;

	f = fopen(state_path, "wb");
	if (!f) {
		fprintf(stderr, "[gbemu] cannot write state %s\n", state_path);
		return;
	}
	fwrite(GB_STATE_MAGIC, 1, 9, f);
	gbsz = (uint32_t)sizeof(struct gb_s);
	apusz = (uint32_t)sizeof(apu);
	ramsz = (uint32_t)priv->save_size;
	fwrite(&gbsz, 4, 1, f);
	fwrite(&apusz, 4, 1, f);
	fwrite(&ramsz, 4, 1, f);
	fwrite(&tmp, 1, sizeof(tmp), f);
	fwrite(&apu, 1, sizeof(apu), f);
	if (priv->cart_ram && priv->save_size)
		fwrite(priv->cart_ram, 1, priv->save_size, f);
	fclose(f);
	fprintf(stderr, "[gbemu] state saved %s\n", state_path);
}

static int gb_load_state(struct gb_s *gb, struct priv_t *priv, const char *rom_path)
{
	char state_path[512], sav_path[512];
	FILE *f;
	char magic[10];
	uint32_t gbsz, apusz, ramsz;
	struct gb_s tmp;

	gb_state_paths(rom_path, state_path, sizeof(state_path), sav_path, sizeof(sav_path));
	gb_load_sram(priv, sav_path);

	f = fopen(state_path, "rb");
	if (!f)
		return 0;
	if (fread(magic, 1, 9, f) != 9 || memcmp(magic, GB_STATE_MAGIC, 9) != 0) {
		fclose(f);
		fprintf(stderr, "[gbemu] bad state magic\n");
		return 0;
	}
	if (fread(&gbsz, 4, 1, f) != 1 || fread(&apusz, 4, 1, f) != 1 ||
	    fread(&ramsz, 4, 1, f) != 1) {
		fclose(f);
		return 0;
	}
	if (gbsz != sizeof(struct gb_s) || apusz != sizeof(apu)) {
		fclose(f);
		fprintf(stderr, "[gbemu] state size mismatch (rebuild?)\n");
		return 0;
	}
	if (fread(&tmp, 1, sizeof(tmp), f) != sizeof(tmp)) {
		fclose(f);
		return 0;
	}
	if (fread(&apu, 1, sizeof(apu), f) != sizeof(apu)) {
		fclose(f);
		return 0;
	}
	/* Restaure pointeurs frontend */
	tmp.gb_rom_read = gb->gb_rom_read;
	tmp.gb_cart_ram_read = gb->gb_cart_ram_read;
	tmp.gb_cart_ram_write = gb->gb_cart_ram_write;
	tmp.gb_error = gb->gb_error;
	tmp.gb_serial_tx = gb->gb_serial_tx;
	tmp.gb_serial_rx = gb->gb_serial_rx;
	tmp.gb_bootrom_read = gb->gb_bootrom_read;
	tmp.display.lcd_draw_line = gb->display.lcd_draw_line;
	tmp.direct.priv = priv;
	*gb = tmp;

	if (priv->cart_ram && priv->save_size && ramsz == priv->save_size)
		fread(priv->cart_ram, 1, priv->save_size, f);
	fclose(f);
	fprintf(stderr, "[gbemu] state loaded %s\n", state_path);
	return 1;
}

static void setup_alsa_spk(void)
{
	system("amixer -c 0 cset name='Playback Path' SPK 2>/dev/null || true");
	system("amixer -c 0 sset Playback unmute 2>/dev/null || true");
	system("amixer -c 0 sset DAC unmute 2>/dev/null || true");
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

static int emu_volume_to_hw(int volume)
{
	int hw;
	if (volume <= 0)
		return 0;
	if (volume <= 12)
		hw = (volume * 204) / 12;
	else
		hw = 204 + ((volume - 12) * (255 - 204)) / (25 - 12);
	if (hw < 40)
		hw = 40;
	if (hw > 255)
		hw = 255;
	return hw;
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
	fprintf(stderr, "[gbemu] volume %d/25\n", emu_volume);
}

static int init_audio(void)
{
	SDL_AudioSpec want, have;

	setenv("SDL_AUDIODRIVER", "alsa", 0);
	memset(&want, 0, sizeof(want));
	want.freq = AUDIO_SAMPLE_RATE;
	want.format = AUDIO_S16SYS;
	want.channels = 2;
	want.samples = (Uint16)AUDIO_SAMPLES;
	want.callback = NULL;
	want.userdata = NULL;

	audio_dev = SDL_OpenAudioDevice(NULL, 0, &want, &have, 0);
	if (audio_dev == 0) {
		fprintf(stderr, "[gbemu] audio: %s\n", SDL_GetError());
		return -1;
	}
	minigb_apu_audio_init(&apu);
	SDL_PauseAudioDevice(audio_dev, 0);
	fprintf(stderr, "[gbemu] audio %d Hz queue-sync (%s)\n",
		have.freq, SDL_GetCurrentAudioDriver() ? SDL_GetCurrentAudioDriver() : "?");
	return 0;
}

/* 1 frame APU → file SDL ; cadence sur la file (reste sync vidéo/audio) */
static void push_audio_frame(void)
{
	const Uint32 frame_bytes = (Uint32)(AUDIO_SAMPLES_TOTAL * sizeof(audio_sample_t));
	const Uint32 max_queued = frame_bytes * 3;

	if (!audio_dev)
		return;
	minigb_apu_audio_callback(&apu, audio_buf);
	SDL_QueueAudio(audio_dev, audio_buf, frame_bytes);
	while (SDL_GetQueuedAudioSize(audio_dev) > max_queued)
		SDL_Delay(1);
}

static void sleep_until(struct timespec *next)
{
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	if (now.tv_sec > next->tv_sec ||
	    (now.tv_sec == next->tv_sec && now.tv_nsec >= next->tv_nsec)) {
		*next = now;
	} else {
		clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, next, NULL);
	}
	next->tv_nsec += FRAME_NS;
	while (next->tv_nsec >= 1000000000L) {
		next->tv_nsec -= 1000000000L;
		next->tv_sec++;
	}
}

int main(int argc, char **argv)
{
	struct gb_s gb;
	struct priv_t priv;
	struct fb_ctx fb;
	enum gb_init_error_e ret;
	size_t rom_len = 0;
	int running = 1;
	const char *rom_path;
	struct timespec next_frame;

	memset(&priv, 0, sizeof(priv));
	memset(&gb, 0, sizeof(gb));
	memset(&apu, 0, sizeof(apu));
	memset(&fb, 0, sizeof(fb));
	fb.fd = -1;

	if (argc < 2) {
		fprintf(stderr, "usage: %s <rom.gb|rom.gbc>\n", argv[0]);
		return 1;
	}
	rom_path = argv[1];

	priv.rom = load_file(rom_path, &rom_len);
	if (!priv.rom) {
		fprintf(stderr, "[gbemu] cannot read %s\n", rom_path);
		return 1;
	}

	ret = gb_init(&gb, gb_rom_read, gb_cart_ram_read, gb_cart_ram_write, gb_error, &priv);
	if (ret != GB_INIT_NO_ERROR) {
		fprintf(stderr, "[gbemu] gb_init failed (%d)\n", (int)ret);
		free(priv.rom);
		return 1;
	}

	priv.save_size = (size_t)gb_get_save_size(&gb);
	if (priv.save_size > 0) {
		priv.cart_ram = (uint8_t *)calloc(1, priv.save_size);
		if (!priv.cart_ram)
			priv.save_size = 0;
	}

	gb_init_lcd(&gb, lcd_draw_line);
	gb.direct.joypad = 0xFF;
	gb.direct.frame_skip = false;

	setup_alsa_spk();
	emu_apply_volume();
	/* Audio only — pas de vidéo SDL (fb0 garde la perf) */
	if (SDL_Init(SDL_INIT_AUDIO) != 0)
		fprintf(stderr, "[gbemu] SDL_Init audio: %s\n", SDL_GetError());
	if (init_audio() != 0)
		fprintf(stderr, "[gbemu] continuing silent\n");
	else
		gb_load_state(&gb, &priv, rom_path);

	fb_unblank();
	if (fb_open(&fb) != 0) {
		fprintf(stderr, "[gbemu] cannot open /dev/fb0\n");
		if (audio_dev)
			SDL_CloseAudioDevice(audio_dev);
		SDL_Quit();
		free(priv.cart_ram);
		free(priv.rom);
		return 1;
	}

	open_inputs();
	fprintf(stderr, "[gbemu] playing %s — VOL+/- volume, MENU/FN quit (+save state)\n", rom_path);

	clock_gettime(CLOCK_MONOTONIC, &next_frame);
	while (running) {
		if (poll_inputs(&gb))
			running = 0;

		gb_run_frame(&gb);
		push_audio_frame();
		present_fb(&fb, &priv);
		sleep_until(&next_frame);
	}

	gb_save_state(&gb, &priv, rom_path);

	close_inputs();
	fb_close(&fb);
	if (emu_mixer_fd >= 0) {
		close(emu_mixer_fd);
		emu_mixer_fd = -1;
	}
	if (audio_dev) {
		SDL_ClearQueuedAudio(audio_dev);
		SDL_PauseAudioDevice(audio_dev, 1);
		SDL_CloseAudioDevice(audio_dev);
	}
	SDL_Quit();
	free(priv.cart_ram);
	free(priv.rom);
	return 0;
}
