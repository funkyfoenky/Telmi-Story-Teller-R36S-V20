#ifndef TELMI_GAME_BROWSER__
#define TELMI_GAME_BROWSER__

#include <dirent.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <sys/stat.h>

#include "./sdl_helper.h"

#define GBROWSER_GAMES_ROOT "/telmi/Games"
#define GBROWSER_LEVEL_CONSOLES 0
#define GBROWSER_LEVEL_ROMS 1
#define GBROWSER_MAX_ROMS 256

struct gbrowser_console {
	const char *id;
	const char *label;
	const char *coverPng;
	const char *const *scanDirs;
	const char *const *exts; /* extensions avec point, NULL-terminated */
	const char *emptyHint;
};

static const char *gbrowser_gb_dirs[] = {
	GBROWSER_GAMES_ROOT "/gb",
	NULL
};
static const char *gbrowser_gbc_dirs[] = {
	GBROWSER_GAMES_ROOT "/gbc",
	NULL
};
static const char *gbrowser_nes_dirs[] = {
	GBROWSER_GAMES_ROOT "/nes",
	NULL
};
static const char *gbrowser_md_dirs[] = {
	GBROWSER_GAMES_ROOT "/md",
	GBROWSER_GAMES_ROOT "/megadrive",
	GBROWSER_GAMES_ROOT "/genesis",
	NULL
};
static const char *gbrowser_snes_dirs[] = {
	GBROWSER_GAMES_ROOT "/snes",
	NULL
};
static const char *gbrowser_gba_dirs[] = {
	GBROWSER_GAMES_ROOT "/gba",
	NULL
};
static const char *gbrowser_psx_dirs[] = {
	GBROWSER_GAMES_ROOT "/psx",
	GBROWSER_GAMES_ROOT "/ps1",
	NULL
};

static const char *gbrowser_gb_exts[] = { ".gb", NULL };
static const char *gbrowser_gbc_exts[] = { ".gbc", NULL };
static const char *gbrowser_nes_exts[] = { ".nes", NULL };
static const char *gbrowser_md_exts[] = { ".md", ".gen", ".smd", ".bin", NULL };
static const char *gbrowser_snes_exts[] = { ".sfc", ".smc", NULL };
static const char *gbrowser_gba_exts[] = { ".gba", NULL };
static const char *gbrowser_psx_exts[] = { ".cue", ".chd", ".pbp", ".iso", ".img", ".bin", NULL };

static const struct gbrowser_console gbrowser_consoles[] = {
	{
		.id = "gb",
		.label = "Game Boy",
		.coverPng = "consoleGameBoy.png",
		.scanDirs = gbrowser_gb_dirs,
		.exts = gbrowser_gb_exts,
		.emptyHint = "Placez des .gb dans Games/gb/"
	},
	{
		.id = "gbc",
		.label = "Game Boy Color",
		.coverPng = "consoleGameBoyColor.png",
		.scanDirs = gbrowser_gbc_dirs,
		.exts = gbrowser_gbc_exts,
		.emptyHint = "Placez des .gbc dans Games/gbc/"
	},
	{
		.id = "gba",
		.label = "Game Boy Advance",
		.coverPng = "consoleGBA.png",
		.scanDirs = gbrowser_gba_dirs,
		.exts = gbrowser_gba_exts,
		.emptyHint = "Placez des .gba dans Games/gba/"
	},
	{
		.id = "nes",
		.label = "NES",
		.coverPng = "consoleNES.png",
		.scanDirs = gbrowser_nes_dirs,
		.exts = gbrowser_nes_exts,
		.emptyHint = "Placez des .nes dans Games/nes/"
	},
	{
		.id = "md",
		.label = "Megadrive",
		.coverPng = "consoleMegadrive.png",
		.scanDirs = gbrowser_md_dirs,
		.exts = gbrowser_md_exts,
		.emptyHint = "Placez des .md/.gen dans Games/md/"
	},
	{
		.id = "snes",
		.label = "SNES",
		.coverPng = "consoleSNES.png",
		.scanDirs = gbrowser_snes_dirs,
		.exts = gbrowser_snes_exts,
		.emptyHint = "Placez des .sfc/.smc dans Games/snes/"
	},
	{
		.id = "psx",
		.label = "PlayStation",
		.coverPng = "consolePSX.png",
		.scanDirs = gbrowser_psx_dirs,
		.exts = gbrowser_psx_exts,
		.emptyHint = "Placez .cue/.chd/.pbp dans Games/psx/ (+ BIOS dans Saves/)"
	}
};

#define GBROWSER_CONSOLE_COUNT ((int)(sizeof(gbrowser_consoles) / sizeof(gbrowser_consoles[0])))

static int gbrowserLevel = GBROWSER_LEVEL_CONSOLES;
static int gbrowserConsoleIndex = 0;
static int gbrowserRomIndex = 0;
static int gbrowserRomCount = 0;
static char (*gbrowserRomPaths)[PATH_MAX] = NULL;
static char (*gbrowserRomNames)[256] = NULL;
static char gbrowserPendingLaunch[PATH_MAX];
static char gbrowserPendingConsole[32];

static int gbrowser_match_ext(const char *name, const char *const *exts)
{
	size_t n, el;
	int i;

	if (!name || name[0] == '.' || !exts)
		return 0;
	n = strlen(name);
	for (i = 0; exts[i] != NULL; i++) {
		el = strlen(exts[i]);
		if (n >= el && strcasecmp(name + n - el, exts[i]) == 0)
			return 1;
	}
	return 0;
}

static int gbrowser_path_already(const char *path)
{
	int i;
	for (i = 0; i < gbrowserRomCount; i++) {
		if (strcmp(gbrowserRomPaths[i], path) == 0)
			return 1;
	}
	return 0;
}

static void gbrowser_free_roms(void)
{
	free(gbrowserRomPaths);
	free(gbrowserRomNames);
	gbrowserRomPaths = NULL;
	gbrowserRomNames = NULL;
	gbrowserRomCount = 0;
	gbrowserRomIndex = 0;
}

static int gbrowser_rom_cmp(const void *a, const void *b)
{
	const char *pa = (const char *)a;
	const char *pb = (const char *)b;
	const char *na = strrchr(pa, '/');
	const char *nb = strrchr(pb, '/');
	na = na ? na + 1 : pa;
	nb = nb ? nb + 1 : pb;
	return strcasecmp(na, nb);
}

static void gbrowser_scan_dir(const char *dir, const char *const *exts)
{
	DIR *d;
	struct dirent *ent;
	char path[PATH_MAX];

	d = opendir(dir);
	if (!d)
		return;

	while ((ent = readdir(d)) != NULL) {
		if (!gbrowser_match_ext(ent->d_name, exts))
			continue;
		snprintf(path, sizeof(path), "%s/%s", dir, ent->d_name);
		if (access(path, R_OK) != 0)
			continue;
		if (gbrowser_path_already(path))
			continue;
		if (gbrowserRomCount >= GBROWSER_MAX_ROMS)
			break;
		snprintf(gbrowserRomPaths[gbrowserRomCount], PATH_MAX, "%s", path);
		snprintf(gbrowserRomNames[gbrowserRomCount], 256, "%s", ent->d_name);
		gbrowserRomCount++;
	}
	closedir(d);
}

static void gbrowser_load_roms(int consoleIdx)
{
	const struct gbrowser_console *c;
	int i;

	gbrowser_free_roms();
	if (consoleIdx < 0 || consoleIdx >= GBROWSER_CONSOLE_COUNT)
		return;

	c = &gbrowser_consoles[consoleIdx];
	gbrowserRomPaths = calloc(GBROWSER_MAX_ROMS, PATH_MAX);
	gbrowserRomNames = calloc(GBROWSER_MAX_ROMS, 256);
	if (!gbrowserRomPaths || !gbrowserRomNames) {
		gbrowser_free_roms();
		return;
	}

	for (i = 0; c->scanDirs[i] != NULL; i++)
		gbrowser_scan_dir(c->scanDirs[i], c->exts);

	if (gbrowserRomCount > 1)
		qsort(gbrowserRomPaths, (size_t)gbrowserRomCount, PATH_MAX, gbrowser_rom_cmp);

	for (i = 0; i < gbrowserRomCount; i++) {
		const char *base = strrchr(gbrowserRomPaths[i], '/');
		base = base ? base + 1 : gbrowserRomPaths[i];
		snprintf(gbrowserRomNames[i], 256, "%s", base);
	}
	gbrowserRomIndex = 0;
}

static void gbrowser_cover_for_rom(int romIdx, char *dirOut, size_t dirSz, char *fileOut, size_t fileSz)
{
	char base[256];
	char *dot;
	const char *slash;
	char dir[PATH_MAX];

	snprintf(dirOut, dirSz, "%s", SYSTEM_RESOURCES);
	snprintf(fileOut, fileSz, "gameDefaultCover.png");

	if (romIdx < 0 || romIdx >= gbrowserRomCount)
		return;

	slash = strrchr(gbrowserRomPaths[romIdx], '/');
	if (!slash)
		return;
	snprintf(dir, sizeof(dir), "%.*s", (int)(slash - gbrowserRomPaths[romIdx] + 1), gbrowserRomPaths[romIdx]);
	snprintf(base, sizeof(base), "%s", slash + 1);
	dot = strrchr(base, '.');
	if (dot)
		*dot = '\0';
	{
		char tryPath[PATH_MAX];
		snprintf(tryPath, sizeof(tryPath), "%s%s.png", dir, base);
		if (access(tryPath, R_OK) == 0) {
			snprintf(dirOut, dirSz, "%s", dir);
			snprintf(fileOut, fileSz, "%s.png", base);
		}
	}
}

static void gbrowser_draw_tile(int base, int pos, int selectedIndex, int count,
			       int isConsoleLevel)
{
	int idx = base + pos;
	int x, y;
	char coverDir[PATH_MAX];
	char coverFile[256];

	if (idx >= count)
		return;

	x = 33 + (pos % 3) * 201;
	y = 28 + (pos / 3) * 148;

	if (selectedIndex == idx)
		video_drawRectangle(x - 5, y - 5, 181, 138, 255, 186, 0);
	video_drawRectangle(x, y, 171, 128, 0, 0, 0);

	if (isConsoleLevel) {
		char nameBuf[64];
		snprintf(nameBuf, sizeof(nameBuf), "%s", gbrowser_consoles[idx].coverPng);
		video_screenAddImageFit(SYSTEM_RESOURCES, nameBuf, x, y, 171, 128);
		video_screenWriteFont(gbrowser_consoles[idx].label, fontRegular16, colorWhite,
				     x + 85, y + 108, SDL_ALIGN_CENTER);
	} else {
		gbrowser_cover_for_rom(idx, coverDir, sizeof(coverDir), coverFile, sizeof(coverFile));
		video_screenAddImageFit(coverDir, coverFile, x, y, 171, 128);
		{
			char label[64];
			char *dot;
			snprintf(label, sizeof(label), "%s", gbrowserRomNames[idx]);
			dot = strrchr(label, '.');
			if (dot)
				*dot = '\0';
			if (strlen(label) > 18)
				label[18] = '\0';
			video_screenWriteFont(label, fontRegular16, colorWhite60,
					     x + 85, y + 108, SDL_ALIGN_CENTER);
		}
	}
}

static void gbrowser_draw(void)
{
	int selected, count, page, base, i;
	char writePage[64];
	int consoles = (gbrowserLevel == GBROWSER_LEVEL_CONSOLES);

	if (consoles) {
		selected = gbrowserConsoleIndex;
		count = GBROWSER_CONSOLE_COUNT;
	} else {
		selected = gbrowserRomIndex;
		count = gbrowserRomCount;
	}

	if (count <= 0) {
		const char *hint = "Aucun jeu";
		video_screenAddImage(SYSTEM_RESOURCES, "storiesTiles.png", 0, 0, 640);
		video_screenWriteFont(consoles ? "Aucune console" : "Aucun jeu",
				     fontRegular20, colorWhite, 320, 220, SDL_ALIGN_CENTER);
		if (!consoles && gbrowserConsoleIndex >= 0 &&
		    gbrowserConsoleIndex < GBROWSER_CONSOLE_COUNT)
			hint = gbrowser_consoles[gbrowserConsoleIndex].emptyHint;
		video_screenWriteFont(hint, fontRegular16, colorWhite60, 320, 260, SDL_ALIGN_CENTER);
		video_applyToVideo();
		return;
	}

	if (selected < 0)
		selected = count - 1;
	if (selected >= count)
		selected = 0;
	if (consoles)
		gbrowserConsoleIndex = selected;
	else
		gbrowserRomIndex = selected;

	page = selected / 9;
	base = page * 9;
	snprintf(writePage, sizeof(writePage), "%i / %i", selected + 1, count);

	video_screenAddImage(SYSTEM_RESOURCES, "storiesTiles.png", 0, 0, 640);
	for (i = 0; i < 9; i++)
		gbrowser_draw_tile(base, i, selected, count, consoles);
	video_screenWriteFont(writePage, fontRegular16, colorWhite60, 606, 456, SDL_ALIGN_RIGHT);
	video_applyToVideo();
}

static void gbrowser_move(int delta)
{
	int *idx;
	int count;

	if (gbrowserLevel == GBROWSER_LEVEL_CONSOLES) {
		idx = &gbrowserConsoleIndex;
		count = GBROWSER_CONSOLE_COUNT;
	} else {
		idx = &gbrowserRomIndex;
		count = gbrowserRomCount;
	}
	if (count <= 0)
		return;
	*idx += delta;
	while (*idx < 0)
		*idx += count;
	while (*idx >= count)
		*idx -= count;
	gbrowser_draw();
}

void gamebrowser_init(void)
{
	gbrowserLevel = GBROWSER_LEVEL_CONSOLES;
	gbrowserConsoleIndex = 0;
	gbrowserPendingLaunch[0] = '\0';
	gbrowserPendingConsole[0] = '\0';
	gbrowser_free_roms();
	mkdir(GBROWSER_GAMES_ROOT, 0755);
	mkdir(GBROWSER_GAMES_ROOT "/gb", 0755);
	mkdir(GBROWSER_GAMES_ROOT "/gbc", 0755);
	mkdir(GBROWSER_GAMES_ROOT "/gba", 0755);
	mkdir(GBROWSER_GAMES_ROOT "/nes", 0755);
	mkdir(GBROWSER_GAMES_ROOT "/md", 0755);
	mkdir(GBROWSER_GAMES_ROOT "/snes", 0755);
	mkdir(GBROWSER_GAMES_ROOT "/psx", 0755);
	autosleep_unlock(parameters_getScreenOnInactivityTime(), parameters_getScreenOffInactivityTime());
	gbrowser_draw();
}

void gamebrowser_update(void)
{
}

void gamebrowser_forceRefreshScreen(void)
{
	gbrowser_draw();
}

void gamebrowser_previous(void)
{
	gbrowser_move(-1);
}

void gamebrowser_next(void)
{
	gbrowser_move(1);
}

void gamebrowser_up(void)
{
	gbrowser_move(-3);
}

void gamebrowser_down(void)
{
	gbrowser_move(3);
}

void gamebrowser_menu(void)
{
}

const char *gamebrowser_currentConsoleId(void)
{
	if (gbrowserConsoleIndex < 0 || gbrowserConsoleIndex >= GBROWSER_CONSOLE_COUNT)
		return "gb";
	return gbrowser_consoles[gbrowserConsoleIndex].id;
}

/* Retourne 1 si une ROM est prete a lancer (chemin dans outPath) */
int gamebrowser_ok(char *outPath, size_t outSz)
{
	if (gbrowserLevel == GBROWSER_LEVEL_CONSOLES) {
		if (GBROWSER_CONSOLE_COUNT <= 0)
			return 0;
		gbrowser_load_roms(gbrowserConsoleIndex);
		gbrowserLevel = GBROWSER_LEVEL_ROMS;
		gbrowser_draw();
		return 0;
	}

	if (gbrowserRomCount <= 0 || gbrowserRomIndex < 0 || gbrowserRomIndex >= gbrowserRomCount)
		return 0;

	snprintf(outPath, outSz, "%s", gbrowserRomPaths[gbrowserRomIndex]);
	snprintf(gbrowserPendingLaunch, sizeof(gbrowserPendingLaunch), "%s", outPath);
	snprintf(gbrowserPendingConsole, sizeof(gbrowserPendingConsole), "%s",
		 gamebrowser_currentConsoleId());
	return 1;
}

/* true = quitter le browser vers le carrousel */
bool gamebrowser_home(void)
{
	if (gbrowserLevel == GBROWSER_LEVEL_ROMS) {
		gbrowserLevel = GBROWSER_LEVEL_CONSOLES;
		gbrowser_free_roms();
		gbrowser_draw();
		return false;
	}
	gbrowser_free_roms();
	return true;
}

#endif /* TELMI_GAME_BROWSER__ */
