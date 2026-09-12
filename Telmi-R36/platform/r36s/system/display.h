#ifndef DISPLAY_H__
#define DISPLAY_H__

#include <fcntl.h>
#include <linux/fb.h>
#include <dirent.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include "utils/file.h"
#include "utils/log.h"

#define display_on() display_setScreen(true)
#define display_off() display_setScreen(false)

static int DISPLAY_WIDTH = 640;
static int DISPLAY_HEIGHT = 480;

static uint32_t *fb_addr;
static int fb_fd = -1;
static struct fb_fix_screeninfo finfo;
static bool display_enabled = true;

void display_init(void)
{
	/* SDL gère l'affichage sur R36S — pas de mmap fb en parallèle */
	fb_fd = -1;
	fb_addr = NULL;
}

void display_getResolution(void)
{
	FILE *file = fopen("/tmp/screen_resolution", "r");
	if (file == NULL)
		return;
	fscanf(file, "%dx%d", &DISPLAY_WIDTH, &DISPLAY_HEIGHT);
	fclose(file);
}

void display_save(void) {}
void display_restore(void) {}
void display_reset(void) {}

void display_setScreen(bool enabled)
{
	/* fb0 : blanker le panneau en lecture (écran noir Telmi). */
	file_write("/sys/class/graphics/fb0/blank", enabled ? "0" : "1", 1);
	display_enabled = enabled;
}

void display_toggle(void) { display_setScreen(!display_enabled); }

/* ArkOS/R36S : /sys/class/backlight/backlight/brightness (pwm-backlight) */
static int display_sysfs_writable(const char *path)
{
	FILE *f = fopen(path, "w");
	if (!f)
		return 0;
	fclose(f);
	return 1;
}

static const char *display_backlight_path(void)
{
	static char path[160];
	static int resolved = 0;
	DIR *d;
	struct dirent *ent;

	/* Reessayer si precedent echec (backlight peut apparaitre apres boot) */
	if (resolved && path[0])
		return path;
	if (resolved && !path[0])
		resolved = 0;

	resolved = 1;
	path[0] = '\0';

	if (access("/sys/class/backlight/backlight/brightness", F_OK) == 0 &&
	    display_sysfs_writable("/sys/class/backlight/backlight/brightness")) {
		snprintf(path, sizeof(path), "/sys/class/backlight/backlight/brightness");
		return path;
	}

	d = opendir("/sys/class/backlight");
	if (!d) {
		printf_debug("backlight: no /sys/class/backlight\n");
		return NULL;
	}
	while ((ent = readdir(d)) != NULL) {
		char cand[180];
		if (ent->d_name[0] == '.')
			continue;
		snprintf(cand, sizeof(cand), "/sys/class/backlight/%s/brightness", ent->d_name);
		if (access(cand, F_OK) == 0 && display_sysfs_writable(cand)) {
			snprintf(path, sizeof(path), "%s", cand);
			break;
		}
	}
	closedir(d);
	if (!path[0])
		printf_debug("backlight: no writable brightness node\n");
	return path[0] ? path : NULL;
}

static int display_backlight_max(void)
{
	char max_path[180];
	const char *br = display_backlight_path();
	FILE *f;
	int maxv = 255;
	char *slash;

	if (!br)
		return 255;
	snprintf(max_path, sizeof(max_path), "%s", br);
	slash = strrchr(max_path, '/');
	if (!slash)
		return 255;
	snprintf(slash + 1, sizeof(max_path) - (size_t)(slash + 1 - max_path), "max_brightness");
	f = fopen(max_path, "r");
	if (f) {
		if (fscanf(f, "%d", &maxv) != 1 || maxv <= 0)
			maxv = 255;
		fclose(f);
	}
	return maxv;
}

void display_setBrightnessRaw(uint32_t value)
{
	const char *path = display_backlight_path();
	char buf[32];
	int maxv;
	FILE *f;
	size_t n;

	if (!path)
		return;
	maxv = display_backlight_max();
	if ((int)value > maxv)
		value = (uint32_t)maxv;
	/* newline comme echo(1) — certains drivers sysfs l'attendent */
	n = (size_t)snprintf(buf, sizeof(buf), "%u\n", value);
	f = fopen(path, "w");
	if (!f) {
		printf_debug("backlight: fopen(%s) failed\n", path);
		return;
	}
	fwrite(buf, 1, n, f);
	fflush(f);
	fclose(f);
	printf_debug("backlight: %s = %u (max %d)\n", path, value, maxv);
}

/* value : 0..10 (echelle settings Telmi) → 0..max_brightness */
void display_setBrightness(uint32_t value)
{
	int maxv = display_backlight_max();
	uint32_t raw;

	if (value > 10)
		value = 10;
	/* Evite ecran totalement noir a 0 : minimum ~4% */
	if (value == 0)
		raw = (uint32_t)(maxv / 25);
	else
		raw = (uint32_t)((value * maxv) / 10);
	if (raw < 1)
		raw = 1;
	if ((int)raw > maxv)
		raw = (uint32_t)maxv;
	display_setBrightnessRaw(raw);
}

void display_drawFrame(uint32_t color)
{
	(void)color;
}

void display_drawBatteryIcon(uint32_t color, int x, int y, int level, bool charging, bool show_percent)
{
	(void)color;
	(void)x;
	(void)y;
	(void)level;
	(void)charging;
	(void)show_percent;
}

void display_free(void)
{
	if (fb_addr != NULL && fb_addr != MAP_FAILED) {
		munmap(fb_addr, finfo.smem_len);
		fb_addr = NULL;
	}
	if (fb_fd >= 0) {
		close(fb_fd);
		fb_fd = -1;
	}
}

#endif
