#ifndef STORYTELLER_APP_SELECTOR__
#define STORYTELLER_APP_SELECTOR__

#include "system/display.h"
#include "system/keymap_hw.h"
#include <limits.h>
#include <stdio.h>
#include <string.h>

#define APP_COUNT_BASE 3
#define APP_COUNT_MAX 4
#define APP_STORIES 0
#define APP_MUSIC 1
#define APP_NIGHTMODE 2
#define APP_GAME 3

#ifndef SYSTEM_RESOURCES
#define SYSTEM_RESOURCES "/mnt/SDCARD/.tmp_update/res/"
#endif
#define APP_SAVEFILE "/mnt/SDCARD/Saves/.storytellerState"
#define APP_PARAMETERS_TELMI "/telmi/Saves/.parameters"
#define APP_PARAMETERS_LEGACY "/mnt/SDCARD/Saves/.parameters"
#define GAME_UNLOCK_COMBO_MAX 8
#define GAME_UNLOCK_TIMEOUT_MS 3000

#include "./sdl_helper.h"
#include "music_player.h"
#include "stories_reader.h"
#include "./game_browser.h"

static char appImages[APP_COUNT_MAX][32] = {
	"selectStories.png",
	"selectMusic.png",
	"selectNightMode.png",
	"selectGameMode.png"
};

static int appIndex = 0;
static bool appOpened = false;
static int appCount = APP_COUNT_BASE;
static bool gameUnlocked = false;
static char appLaunchRomPath[PATH_MAX];
static char appLaunchConsoleId[32];

/* Combo menu jeux : sequence de boutons (defaut SELECT x3), depuis .parameters */
static char gameUnlockCombo[GAME_UNLOCK_COMBO_MAX][16];
static int gameUnlockComboLen = 3;
static int gameUnlockProgress = 0;
static Uint32 gameUnlockLastMs = 0;

static void game_unlock_set_default(void)
{
	gameUnlockComboLen = 3;
	snprintf(gameUnlockCombo[0], sizeof(gameUnlockCombo[0]), "SELECT");
	snprintf(gameUnlockCombo[1], sizeof(gameUnlockCombo[1]), "SELECT");
	snprintf(gameUnlockCombo[2], sizeof(gameUnlockCombo[2]), "SELECT");
	gameUnlockProgress = 0;
}

static int game_unlock_valid_name(const char *n)
{
	static const char *ok[] = {
		"UP", "DOWN", "LEFT", "RIGHT",
		"A", "B", "X", "Y",
		"L1", "R1", "L2", "R2",
		"START", "SELECT", NULL
	};
	int i;
	if (!n || !n[0])
		return 0;
	for (i = 0; ok[i]; i++) {
		if (strcmp(n, ok[i]) == 0)
			return 1;
	}
	return 0;
}

static const char *game_unlock_name_from_code(unsigned code)
{
	if (code == HW_BTN_UP) return "UP";
	if (code == HW_BTN_DOWN) return "DOWN";
	if (code == HW_BTN_LEFT) return "LEFT";
	if (code == HW_BTN_RIGHT) return "RIGHT";
	if (code == HW_BTN_A) return "A";
	if (code == HW_BTN_B) return "B";
	if (code == HW_BTN_X) return "X";
	if (code == HW_BTN_Y) return "Y";
	if (code == HW_BTN_L1) return "L1";
	if (code == HW_BTN_R1) return "R1";
	if (code == HW_BTN_L2) return "L2";
	if (code == HW_BTN_R2) return "R2";
	if (HW_BTN_IS_START(code)) return "START";
	if (HW_BTN_IS_SELECT(code)) return "SELECT";
	return NULL;
}

static void game_unlock_load_from_json(cJSON *root)
{
	cJSON *arr;
	int i, n;

	if (!root)
		return;
	arr = cJSON_GetObjectItem(root, "gameUnlockCombo");
	if (!cJSON_IsArray(arr))
		return;
	n = cJSON_GetArraySize(arr);
	if (n < 1)
		return;
	if (n > GAME_UNLOCK_COMBO_MAX)
		n = GAME_UNLOCK_COMBO_MAX;
	gameUnlockComboLen = 0;
	for (i = 0; i < n; i++) {
		cJSON *it = cJSON_GetArrayItem(arr, i);
		const char *s;
		if (!cJSON_IsString(it) || !it->valuestring)
			continue;
		s = it->valuestring;
		if (!game_unlock_valid_name(s))
			continue;
		snprintf(gameUnlockCombo[gameUnlockComboLen],
			 sizeof(gameUnlockCombo[0]), "%s", s);
		gameUnlockComboLen++;
	}
	if (gameUnlockComboLen < 1)
		game_unlock_set_default();
}

static void game_unlock_init(void)
{
	cJSON *params;

	game_unlock_set_default();
	params = json_load(APP_PARAMETERS_TELMI);
	if (!params)
		params = json_load(APP_PARAMETERS_LEGACY);
	if (params) {
		game_unlock_load_from_json(params);
		cJSON_Delete(params);
	}
	fprintf(stderr, "[telmi] game unlock combo len=%d (", gameUnlockComboLen);
	{
		int i;
		for (i = 0; i < gameUnlockComboLen; i++) {
			fprintf(stderr, "%s%s", i ? "+" : "", gameUnlockCombo[i]);
		}
	}
	fprintf(stderr, ")\n");
	fflush(stderr);
}

static void game_unlock_do_unlock(void)
{
	gameUnlocked = true;
	gameUnlockProgress = 0;
	appCount = APP_COUNT_MAX;
	appIndex = APP_GAME;
	app_refreshScreen();
	fprintf(stderr, "[telmi] game mode unlocked\n");
	fflush(stderr);
}

/**
 * Sur carrousel : avance la combo. Retourne 1 si l'evenement est consomme
 * (ne pas executer l'action normale du bouton).
 */
int app_tryGameUnlock(unsigned code)
{
	const char *name;
	Uint32 now;

	if (appOpened || gameUnlocked)
		return 0;
	name = game_unlock_name_from_code(code);
	if (!name)
		return 0;

	now = SDL_GetTicks();
	if (gameUnlockProgress > 0 &&
	    (now - gameUnlockLastMs) > GAME_UNLOCK_TIMEOUT_MS) {
		gameUnlockProgress = 0;
	}

	if (strcmp(name, gameUnlockCombo[gameUnlockProgress]) == 0) {
		gameUnlockProgress++;
		gameUnlockLastMs = now;
		fprintf(stderr, "[telmi] unlock cheat %d/%d (%s)\n",
			gameUnlockProgress, gameUnlockComboLen, name);
		fflush(stderr);
		if (gameUnlockProgress >= gameUnlockComboLen)
			game_unlock_do_unlock();
		return 1;
	}

	/* Mauvais bouton : reset ; reessaie si c'est le 1er de la sequence */
	if (gameUnlockProgress > 0) {
		gameUnlockProgress = 0;
		if (strcmp(name, gameUnlockCombo[0]) == 0) {
			gameUnlockProgress = 1;
			gameUnlockLastMs = now;
			fprintf(stderr, "[telmi] unlock cheat 1/%d (%s) [restart]\n",
				gameUnlockComboLen, name);
			fflush(stderr);
			return 1;
		}
	}
	return 0;
}

/* Compat : Select seul (ancien flux) */
void app_selectPressed(void)
{
	app_tryGameUnlock(HW_BTN_SELECT);
}

int app_validAppIndex(int currentAppIndex, int direction) {
	int newAppIndex = currentAppIndex + direction;
	if (newAppIndex >= appCount) {
		return app_validAppIndex(-1 * direction, direction);
	}
	if (newAppIndex < 0) {
		return app_validAppIndex(appCount - 1 - direction, direction);
	}
	if (newAppIndex == APP_NIGHTMODE && parameters_getStoryDisableNightMode()) {
		return app_validAppIndex(newAppIndex, direction);
	}
	if (newAppIndex == APP_GAME && !gameUnlocked) {
		return app_validAppIndex(newAppIndex, direction);
	}
	return newAppIndex;
}

void app_refreshScreen(void) {
	video_displayImage(SYSTEM_RESOURCES, appImages[appIndex]);
	display_setScreen(true);
	autosleep_unlock(parameters_getScreenOnInactivityTime(), parameters_getScreenOffInactivityTime());
}

void app_update(void) {
	if (appOpened) {
		switch (appIndex) {
			case APP_STORIES:
			case APP_NIGHTMODE:
				stories_update();
				break;
			case APP_MUSIC:
				musicplayer_update();
				break;
			case APP_GAME:
				gamebrowser_update();
				break;
			default:
				break;
		}
	}
}

void app_forceRefreshScreen(void) {
	if (appOpened) {
		switch (appIndex) {
			case APP_STORIES:
			case APP_NIGHTMODE:
				stories_forceRefreshScreen();
				break;
			case APP_MUSIC:
				musicplayer_forceRefreshScreen();
				break;
			case APP_GAME:
				gamebrowser_forceRefreshScreen();
				break;
			default:
				break;
		}
	} else {
		app_refreshScreen();
	}
}

void app_menu(void) {
	if (appOpened) {
		switch (appIndex) {
			case APP_STORIES:
			case APP_NIGHTMODE:
				stories_menu();
				break;
			case APP_MUSIC:
				musicplayer_menu();
				break;
			case APP_GAME:
				gamebrowser_menu();
				break;
			default:
				break;
		}
	}
}

void app_previous(void) {
	if (appOpened) {
		switch (appIndex) {
			case APP_STORIES:
			case APP_NIGHTMODE:
				stories_previous();
				break;
			case APP_MUSIC:
				musicplayer_previous();
				break;
			case APP_GAME:
				gamebrowser_previous();
				break;
			default:
				break;
		}
	} else {
		appIndex = app_validAppIndex(appIndex, -1);
		app_refreshScreen();
	}
}

void app_next(void) {
	if (appOpened) {
		switch (appIndex) {
			case APP_STORIES:
			case APP_NIGHTMODE:
				stories_next();
				break;
			case APP_MUSIC:
				musicplayer_next();
				break;
			case APP_GAME:
				gamebrowser_next();
				break;
			default:
				break;
		}
	} else {
		appIndex = app_validAppIndex(appIndex, 1);
		app_refreshScreen();
	}
}

void app_randomStory(void) {
	if (appOpened) {
		switch (appIndex) {
			case APP_STORIES:
			case APP_NIGHTMODE:
				stories_randomStory();
				break;
			default:
				break;
		}
	}
}

void app_randomChoice(void) {
	if (appOpened) {
		switch (appIndex) {
			case APP_STORIES:
			case APP_NIGHTMODE:
				stories_randomChoice();
				break;
			default:
				break;
		}
	}
}

void app_up(void) {
	if (appOpened) {
		switch (appIndex) {
			case APP_STORIES:
			case APP_NIGHTMODE:
				stories_up();
				break;
			case APP_MUSIC:
				musicplayer_up();
				break;
			case APP_GAME:
				gamebrowser_up();
				break;
			default:
				break;
		}
	}
}

void app_down(void) {
	if (appOpened) {
		switch (appIndex) {
			case APP_STORIES:
			case APP_NIGHTMODE:
				stories_down();
				break;
			case APP_MUSIC:
				musicplayer_down();
				break;
			case APP_GAME:
				gamebrowser_down();
				break;
			default:
				break;
		}
	}
}

void app_pause(void) {
	if (appOpened) {
		switch (appIndex) {
			case APP_STORIES:
			case APP_NIGHTMODE:
				stories_pause();
				break;
			case APP_MUSIC:
				musicplayer_pause();
				break;
			default:
				break;
		}
	}
}

/* Retourne 1 si le caller doit lancer l'ému ; chemin via app_getLaunchRomPath() */
int app_ok(void) {
	appLaunchRomPath[0] = '\0';
	appLaunchConsoleId[0] = '\0';

	if (appOpened) {
		switch (appIndex) {
			case APP_STORIES:
			case APP_NIGHTMODE:
				stories_ok();
				break;
			case APP_MUSIC:
				musicplayer_ok();
				break;
			case APP_GAME:
				if (gamebrowser_ok(appLaunchRomPath, sizeof(appLaunchRomPath))) {
					snprintf(appLaunchConsoleId, sizeof(appLaunchConsoleId), "%s",
						 gamebrowser_currentConsoleId());
					return 1;
				}
				break;
			default:
				break;
		}
		return 0;
	}

	appOpened = true;
	switch (appIndex) {
		case APP_STORIES:
			stories_init();
			break;
		case APP_MUSIC:
			musicplayer_init();
			break;
		case APP_NIGHTMODE:
			stories_initNightMode();
			break;
		case APP_GAME:
			if (gameUnlocked)
				gamebrowser_init();
			else {
				appOpened = false;
			}
			break;
		default:
			appOpened = false;
			break;
	}
	return 0;
}

const char *app_getLaunchRomPath(void) {
	return appLaunchRomPath;
}

const char *app_getLaunchConsoleId(void) {
	return appLaunchConsoleId;
}

void app_home(void) {
	if (appOpened) {
		bool appHome = true;
		switch (appIndex) {
			case APP_STORIES:
			case APP_NIGHTMODE:
				appHome = stories_home();
				break;
			case APP_MUSIC:
				appHome = musicplayer_home();
				break;
			case APP_GAME:
				appHome = gamebrowser_home();
				break;
			default:
				break;
		}
		if (appHome) {
			appOpened = false;
			app_refreshScreen();
		}
	}
}

void app_save(void) {
	if (appOpened) {
		switch (appIndex) {
			case APP_STORIES:
			case APP_NIGHTMODE:
				stories_save();
				break;
			case APP_MUSIC:
				musicplayer_save();
				break;
			default:
				break;
		}
	}
}

void app_init(void) {
	game_unlock_init();
	cJSON *savedState = json_load(APP_SAVEFILE);
	if (json_getInt(savedState, "app", &appIndex)) {
		if (appIndex == APP_GAME)
			appIndex = APP_STORIES;
		app_ok();
	} else {
		app_refreshScreen();
	}
}

#endif /* STORYTELLER_APP_SELECTOR__ */
