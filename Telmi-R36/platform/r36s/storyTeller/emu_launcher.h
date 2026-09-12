#ifndef TELMI_EMU_LAUNCHER__
#define TELMI_EMU_LAUNCHER__

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <sys/wait.h>
#include <limits.h>

#include "sdl_helper.h"

#define TELMI_STORYTELLER_BIN "/opt/telmi/bin/storyTeller"
#define TELMI_LR_BIN "/opt/telmi/bin/telmi_lr"
#define TELMI_GB_BIN "/opt/telmi/bin/gambatte_sdl"
#define TELMI_CORES_DIR "/opt/telmi/lib/cores"

struct telmi_emu_entry {
	const char *console_id;
	const char *bin;       /* binaire standalone, ou telmi_lr */
	const char *core_so;   /* NULL si standalone ; sinon nom .so sous TELMI_CORES_DIR */
};

static const struct telmi_emu_entry telmi_emus[] = {
	{ "gb",  TELMI_LR_BIN, "gambatte_libretro.so" },
	{ "gbc", TELMI_LR_BIN, "gambatte_libretro.so" },
	{ "gba", TELMI_LR_BIN, "mgba_libretro.so" },
	{ "nes", TELMI_LR_BIN, "fceumm_libretro.so" },
	{ "md",  TELMI_LR_BIN, "picodrive_libretro.so" },
	{ "snes", TELMI_LR_BIN, "snes9x2005_libretro.so" },
	{ "psx", TELMI_LR_BIN, "pcsx_rearmed_libretro.so" },
};

static const struct telmi_emu_entry *telmi_find_emu(const char *console_id)
{
	size_t i;
	if (!console_id)
		return NULL;
	for (i = 0; i < sizeof(telmi_emus) / sizeof(telmi_emus[0]); i++) {
		if (strcmp(telmi_emus[i].console_id, console_id) == 0)
			return &telmi_emus[i];
	}
	return NULL;
}

static int telmi_find_core(const char *so_name, char *out, size_t outsz)
{
	static const char *dirs[] = {
		TELMI_CORES_DIR,
		"/home/ark/.config/retroarch/cores",
		"/opt/retroarch/cores",
		"/usr/lib/aarch64-linux-gnu/libretro",
		NULL
	};
	int i;

	if (!so_name)
		return -1;
	for (i = 0; dirs[i]; i++) {
		snprintf(out, outsz, "%s/%s", dirs[i], so_name);
		if (access(out, R_OK) == 0)
			return 0;
	}
	return -1;
}

static const char *telmi_find_retroarch(void)
{
	static const char *bins[] = {
		"/usr/local/bin/retroarch",
		"/usr/bin/retroarch",
		"/opt/retroarch/bin/retroarch",
		NULL
	};
	int i;
	for (i = 0; bins[i]; i++) {
		if (access(bins[i], X_OK) == 0)
			return bins[i];
	}
	return NULL;
}

/**
 * Lance l'emu pour console_id + rom, puis re-exec storyTeller.
 */
static void telmi_launch_rom(const char *console_id, const char *rom_path)
{
	const struct telmi_emu_entry *e;
	pid_t pid;
	int status;
	char core_path[PATH_MAX];
	const char *ra;
	int use_lr = 0;

	if (!rom_path || !rom_path[0] || access(rom_path, R_OK) != 0) {
		fprintf(stderr, "[telmi] ROM invalide : %s\n", rom_path ? rom_path : "(null)");
		fflush(stderr);
		return;
	}

	e = telmi_find_emu(console_id);
	if (!e) {
		size_t n = strlen(rom_path);
		if (n >= 4 && strcasecmp(rom_path + n - 3, ".gb") == 0)
			e = telmi_find_emu("gb");
		else if (n >= 5 && strcasecmp(rom_path + n - 4, ".gbc") == 0)
			e = telmi_find_emu("gbc");
		else if (n >= 5 && strcasecmp(rom_path + n - 4, ".gba") == 0)
			e = telmi_find_emu("gba");
		else if (n >= 5 && strcasecmp(rom_path + n - 4, ".nes") == 0)
			e = telmi_find_emu("nes");
		else if (n >= 5 && (strcasecmp(rom_path + n - 4, ".sfc") == 0 ||
				    strcasecmp(rom_path + n - 4, ".smc") == 0))
			e = telmi_find_emu("snes");
		else if (n >= 5 && (strcasecmp(rom_path + n - 4, ".cue") == 0 ||
				    strcasecmp(rom_path + n - 4, ".chd") == 0 ||
				    strcasecmp(rom_path + n - 4, ".pbp") == 0 ||
				    strcasecmp(rom_path + n - 4, ".iso") == 0))
			e = telmi_find_emu("psx");
		else
			e = telmi_find_emu("md");
	}
	if (!e) {
		fprintf(stderr, "[telmi] console inconnue : %s\n", console_id ? console_id : "?");
		fflush(stderr);
		return;
	}

	if (e->core_so && telmi_find_core(e->core_so, core_path, sizeof(core_path)) != 0) {
		if (strcmp(e->core_so, "snes9x2005_libretro.so") == 0)
			telmi_find_core("snes9x_libretro.so", core_path, sizeof(core_path));
		if (access(core_path, R_OK) != 0) {
			fprintf(stderr, "[telmi] core manquant : %s\n", e->core_so);
			fflush(stderr);
			return;
		}
	}

	use_lr = (access(TELMI_LR_BIN, X_OK) == 0);
	ra = telmi_find_retroarch();
	if (!use_lr && !ra) {
		fprintf(stderr, "[telmi] emu manquant (pas de telmi_lr ni retroarch)\n");
		fflush(stderr);
		return;
	}

	fprintf(stderr, "[telmi] launch %s : %s (via %s)\n", e->console_id, rom_path,
		use_lr ? "telmi_lr" : "retroarch");
	fflush(stderr);

	audio_free_music();
	video_audio_quit();

	pid = fork();
	if (pid == 0) {
		if (use_lr)
			execl(TELMI_LR_BIN, "telmi_lr", core_path, rom_path, e->console_id, (char *)NULL);
		else
			execl(ra, "retroarch", "-L", core_path, rom_path, (char *)NULL);
		_exit(127);
	}
	if (pid > 0)
		waitpid(pid, &status, 0);

	execl(TELMI_STORYTELLER_BIN, "storyTeller", (char *)NULL);
	video_audio_init();
}

/* Compat */
static void telmi_launch_gb(const char *rom_path)
{
	telmi_launch_rom("gb", rom_path);
}

#endif
