#ifndef TELMI_EMU_LAUNCHER__
#define TELMI_EMU_LAUNCHER__

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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
	{ "gb",  TELMI_GB_BIN, NULL },
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

/**
 * Lance l'emu pour console_id + rom, puis re-exec storyTeller (kmsdrm).
 */
static void telmi_launch_rom(const char *console_id, const char *rom_path)
{
	const struct telmi_emu_entry *e;
	pid_t pid;
	int status;
	char core_path[PATH_MAX];

	if (!rom_path || !rom_path[0] || access(rom_path, R_OK) != 0) {
		fprintf(stderr, "[telmi] ROM invalide : %s\n", rom_path ? rom_path : "(null)");
		fflush(stderr);
		return;
	}

	e = telmi_find_emu(console_id);
	if (!e) {
		/* Fallback extension */
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

	if (access(e->bin, X_OK) != 0) {
		fprintf(stderr, "[telmi] emu manquant : %s\n", e->bin);
		fflush(stderr);
		return;
	}

	if (e->core_so) {
		snprintf(core_path, sizeof(core_path), "%s/%s", TELMI_CORES_DIR, e->core_so);
		if (access(core_path, R_OK) != 0) {
			fprintf(stderr, "[telmi] core manquant : %s\n", core_path);
			fflush(stderr);
			return;
		}
	}

	fprintf(stderr, "[telmi] launch %s : %s\n", e->console_id, rom_path);
	fflush(stderr);

	audio_free_music();
	video_audio_quit();

	pid = fork();
	if (pid == 0) {
		if (e->core_so)
			execl(e->bin, "telmi_lr", core_path, rom_path, e->console_id, (char *)NULL);
		else
			execl(e->bin, "gambatte_sdl", rom_path, e->console_id, (char *)NULL);
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
