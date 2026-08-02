#ifndef TELMI_GB_LAUNCHER__
#define TELMI_GB_LAUNCHER__

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <limits.h>

#include "sdl_helper.h"

#define GB_EMU_BIN "/opt/telmi/bin/gambatte_sdl"
#define GB_STORYTELLER_BIN "/opt/telmi/bin/storyTeller"

/**
 * Lance l'emu GB avec rom_path puis re-exec storyTeller (propre pour kmsdrm).
 * Ne retourne pas en cas de succes du re-exec.
 */
static void telmi_launch_gb(const char *rom_path)
{
	pid_t pid;
	int status;

	if (!rom_path || !rom_path[0] || access(rom_path, R_OK) != 0) {
		fprintf(stderr, "[telmi] ROM invalide : %s\n", rom_path ? rom_path : "(null)");
		fflush(stderr);
		return;
	}
	if (access(GB_EMU_BIN, X_OK) != 0) {
		fprintf(stderr, "[telmi] emu manquant : %s\n", GB_EMU_BIN);
		fflush(stderr);
		return;
	}

	fprintf(stderr, "[telmi] launch GB : %s\n", rom_path);
	fflush(stderr);

	audio_free_music();
	video_audio_quit();

	pid = fork();
	if (pid == 0) {
		execl(GB_EMU_BIN, "gambatte_sdl", rom_path, (char *)NULL);
		_exit(127);
	}
	if (pid > 0)
		waitpid(pid, &status, 0);

	execl(GB_STORYTELLER_BIN, "storyTeller", (char *)NULL);
	video_audio_init();
}

#endif
