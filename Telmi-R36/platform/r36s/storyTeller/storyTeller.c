#include <fcntl.h>
#include <poll.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <linux/input.h>

#include "system/system.h"
#include "system/keymap_hw.h"
#include "system/telmi_rev.h"
#include "system/settings.h"
#include "system/settings_sync.h"
#include "system/display.h"

#include "./logs_helper.h"
#include "./time_helper.h"
#include "./app_lock.h"
#include "./app_brightness.h"
#include "./app_volume.h"
#include "./app_autosleep.h"
#include "./sdl_helper.h"
#include "./app_selector.h"
#include "./app_parameters.h"
#include "./emu_launcher.h"

#define RELEASED 0
#define PRESSED 1
#define REPEAT 2

#define INPUT_MAX 8

static int input_fds[INPUT_MAX];
static int input_count;
static struct input_event ev;
static struct pollfd fds[INPUT_MAX];
static int active_fd_index;
static int hat_x;
static int hat_y;
static int synth_code = -1;
static int synth_value;
/* VOL deja enfonce au open (ex. zed_keyboard fantome) : ignorer jusqu au release */
static bool ignore_vol_down;
static bool ignore_vol_up;

static bool r36s_has_bit(unsigned long code, const unsigned long *bits, size_t bytes)
{
	size_t bit = code;

	if (bit >= bytes * 8)
		return false;
	return (bits[bit / (8 * sizeof(unsigned long))] >>
		(bit % (8 * sizeof(unsigned long)))) & 1UL;
}

static bool r36s_fd_already_open(int fd)
{
	struct stat st_new, st_old;

	if (fstat(fd, &st_new) != 0)
		return false;
	for (int i = 0; i < input_count; i++) {
		if (input_fds[i] < 0)
			continue;
		if (fstat(input_fds[i], &st_old) == 0 &&
		    st_new.st_dev == st_old.st_dev &&
		    st_new.st_ino == st_old.st_ino)
			return true;
	}
	return false;
}

static void r36s_add_input_fd(int fd, const char *path, const char *name, const char *role)
{
	if (input_count >= INPUT_MAX || fd < 0)
		return;
	if (r36s_fd_already_open(fd)) {
		close(fd);
		return;
	}
	input_fds[input_count] = fd;
	fds[input_count].fd = fd;
	fds[input_count].events = POLLIN;
	fds[input_count].revents = 0;
	fprintf(stderr, "[telmi] input[%d]: %s (%s) — %s\n", input_count, path, name, role);
	fflush(stderr);
	input_count++;
}

/*
 * Sur R36S, Vol+/Vol- et Power sont souvent sur un event gpio-keys
 * distinct de play_joystick. On ouvre tous les event utiles.
 */
static void r36s_open_inputs(void)
{
	unsigned long keybit[(KEY_MAX + 1) / (8 * sizeof(unsigned long)) + 1];
	unsigned long absbit[(ABS_MAX + 1) / (8 * sizeof(unsigned long)) + 1];

	input_count = 0;
	memset(input_fds, -1, sizeof(input_fds));
	memset(fds, 0, sizeof(fds));

	for (int n = 0; n < 32; n++) {
		char evpath[32];
		char name[256] = "";
		int fd;
		int pad_score = 0;
		bool want = false;
		const char *role = "other";

		sprintf(evpath, "/dev/input/event%d", n);
		fd = open(evpath, O_RDONLY | O_NONBLOCK);
		if (fd < 0)
			continue;

		memset(keybit, 0, sizeof(keybit));
		memset(absbit, 0, sizeof(absbit));
		ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(keybit)), keybit);
		ioctl(fd, EVIOCGBIT(EV_ABS, sizeof(absbit)), absbit);
		ioctl(fd, EVIOCGNAME(sizeof(name)), name);

		/*
		 * V30 : play_joystick + DTB clone expose zed_keyboard avec VOL- colle.
		 * V20 : zed_keyboard est le vrai volume. Decide via /boot/TELMI-REV.txt.
		 */
		if (telmi_ignore_zed_keyboard() && strcmp(name, "zed_keyboard") == 0) {
			fprintf(stderr, "[telmi] ignore %s (%s) — phantom volume (rev=%s)\n",
				evpath, name, telmi_rev_id());
			fflush(stderr);
			close(fd);
			continue;
		}

		if (r36s_has_bit(BTN_EAST, keybit, sizeof(keybit)) ||
		    r36s_has_bit(BTN_SOUTH, keybit, sizeof(keybit)))
			pad_score += 2;
		if (r36s_has_bit(BTN_DPAD_UP, keybit, sizeof(keybit)))
			pad_score += 2;
		if (r36s_has_bit(ABS_HAT0X, absbit, sizeof(absbit)))
			pad_score += 2;

		if (pad_score >= 2) {
			want = true;
			role = "gamepad";
		}
		if (r36s_has_bit(KEY_VOLUMEUP, keybit, sizeof(keybit)) ||
		    r36s_has_bit(KEY_VOLUMEDOWN, keybit, sizeof(keybit))) {
			want = true;
			role = (pad_score >= 2) ? "gamepad+volume" : "volume";
		}
		if (r36s_has_bit(KEY_POWER, keybit, sizeof(keybit))) {
			want = true;
			if (pad_score < 2 &&
			    !r36s_has_bit(KEY_VOLUMEUP, keybit, sizeof(keybit)) &&
			    !r36s_has_bit(KEY_VOLUMEDOWN, keybit, sizeof(keybit)))
				role = "power";
		}

		if (want)
			r36s_add_input_fd(fd, evpath, name, role);
		else
			close(fd);
	}

	if (input_count == 0)
		fprintf(stderr, "[telmi] aucun peripherique input\n");

	/* VOL deja colle au demarrage (REPEAT sans PRESSED) */
	ignore_vol_down = false;
	ignore_vol_up = false;
	for (int i = 0; i < input_count; i++) {
		unsigned char key_state[(KEY_MAX + 7) / 8];
		memset(key_state, 0, sizeof(key_state));
		if (ioctl(input_fds[i], EVIOCGKEY(sizeof(key_state)), key_state) < 0)
			continue;
		if (key_state[KEY_VOLUMEDOWN / 8] & (1u << (KEY_VOLUMEDOWN % 8))) {
			ignore_vol_down = true;
			fprintf(stderr, "[telmi] VOL- colle au demarrage (input[%d]) — ignore\n", i);
			fflush(stderr);
		}
		if (key_state[KEY_VOLUMEUP / 8] & (1u << (KEY_VOLUMEUP % 8))) {
			ignore_vol_up = true;
			fprintf(stderr, "[telmi] VOL+ colle au demarrage (input[%d]) — ignore\n", i);
			fflush(stderr);
		}
	}
}

static void r36s_emit_key(int code, int value)
{
	memset(&ev, 0, sizeof(ev));
	ev.type = EV_KEY;
	ev.code = (unsigned int)code;
	ev.value = value;
}

static bool r36s_hat_event(void)
{
	int old_x = hat_x;
	int old_y = hat_y;
	int dir = -1;

	if (ev.code == ABS_HAT0X)
		hat_x = ev.value;
	else if (ev.code == ABS_HAT0Y)
		hat_y = ev.value;
	else
		return false;

	if (hat_x == -1)
		dir = HW_BTN_LEFT;
	else if (hat_x == 1)
		dir = HW_BTN_RIGHT;
	else if (hat_y == -1)
		dir = HW_BTN_UP;
	else if (hat_y == 1)
		dir = HW_BTN_DOWN;

	if (dir >= 0) {
		r36s_emit_key(dir, PRESSED);
		synth_code = dir;
		synth_value = RELEASED;
		return true;
	}

	if (old_x == -1)
		dir = HW_BTN_LEFT;
	else if (old_x == 1)
		dir = HW_BTN_RIGHT;
	else if (old_y == -1)
		dir = HW_BTN_UP;
	else if (old_y == 1)
		dir = HW_BTN_DOWN;
	else
		return false;

	r36s_emit_key(dir, RELEASED);
	return true;
}

bool keyinput_isValid(void) {
	int fd;

	if (synth_code >= 0) {
		r36s_emit_key(synth_code, synth_value);
		synth_code = -1;
		return true;
	}

	if (input_count <= 0 || active_fd_index < 0 || active_fd_index >= input_count)
		return false;

	fd = input_fds[active_fd_index];
	if (fd < 0)
		return false;

	if (read(fd, &ev, sizeof(ev)) != (ssize_t)sizeof(ev))
		return false;

	if (ev.type == EV_ABS && (ev.code == ABS_HAT0X || ev.code == ABS_HAT0Y))
		return r36s_hat_event();

	if (ev.type != EV_KEY || ev.value > REPEAT)
		return false;

	return true;
}

int main(int argc, char *argv[]) {

	srand(time(NULL));
	video_audio_init();
	settings_init();
	display_init();
	parameters_init();
	settings_setVolume(parameters_getAudioVolumeStartup(), true);
	settings_setBrightness(parameters_getScreenBrightnessStartup(), true, false);

	autosleep_init(parameters_getScreenOnInactivityTime(), parameters_getScreenOffInactivityTime());
	app_init();
	app_forceRefreshScreen();

	r36s_open_inputs();

	bool isMenuPressed = false;
	bool menuPreventDefault = false;
	bool startPowerPressed = false;
	long startPowerPressedTime = 0;

	while (1) {
		if (autosleep_isSleepingTime() || (startPowerPressed && (get_time() - startPowerPressedTime) > 1)) {
			goto exit_loop;
		}

		bool forceRefreshScreen = applock_checkLock();
		forceRefreshScreen = app_volume_checkDisplay() || forceRefreshScreen;
		forceRefreshScreen = app_brightness_checkDisplay() || forceRefreshScreen;
		app_update();
		audio_flushPendingSeek();

		bool have_input = (synth_code >= 0);
		if (!have_input && input_count > 0) {
			if (poll(fds, input_count, 0) > 0) {
				for (int i = 0; i < input_count; i++) {
					if (fds[i].revents & POLLIN) {
						active_fd_index = i;
						have_input = true;
						break;
					}
				}
			}
		}

		if (have_input) {
			if (!keyinput_isValid()) {
				continue;
			}

			if (ev.type == EV_KEY && ev.value == PRESSED) {
				fprintf(stderr, "[telmi] key code=%u\n", ev.code);
				fflush(stderr);
			}

			switch (ev.value) {
				case PRESSED:
					if (HW_BTN_IS_MENU(ev.code)) {
						isMenuPressed = true;
						forceRefreshScreen = applock_startTimer() || forceRefreshScreen;
						if (applock_isLocked()) {
							menuPreventDefault = true;
						}
						fprintf(stderr, "[telmi] menu/FN pressed code=%u\n", ev.code);
						fflush(stderr);
						break;
					}
					switch (ev.code) {
						case HW_BTN_POWER :
							if (!applock_isLocked()) {
								startPowerPressedTime = get_time();
								startPowerPressed = true;
							}
							break;
						case HW_BTN_VOLUME_DOWN :
							if (ignore_vol_down)
								break;
							if (!applock_isLocked() && !isMenuPressed) {
								forceRefreshScreen = app_volume_down();
								autosleep_keepAwake();
							}
							break;
						case HW_BTN_VOLUME_UP :
							if (ignore_vol_up)
								break;
							if (!applock_isLocked() && !isMenuPressed) {
								forceRefreshScreen = app_volume_up();
								autosleep_keepAwake();
							}
							break;
					}
					break;

				case RELEASED:
					if (ev.code == HW_BTN_VOLUME_DOWN)
						ignore_vol_down = false;
					else if (ev.code == HW_BTN_VOLUME_UP)
						ignore_vol_up = false;
					if (applock_isLocked()) {
						if (HW_BTN_IS_MENU(ev.code)) {
							forceRefreshScreen = applock_stopTimer() || forceRefreshScreen;
						}
						break;
					}
					autosleep_keepAwake();
					/* Start AVANT Fn : sur clones HAPPY2 etait classe menu. */
					if (HW_BTN_IS_START(ev.code)) {
						fprintf(stderr, "[telmi] START/pause code=%u\n", ev.code);
						fflush(stderr);
						if (time_wait()) {
							app_pause();
						}
						break;
					}
					if (HW_BTN_IS_MENU(ev.code)) {
						if (!menuPreventDefault) {
							app_menu();
						}
						isMenuPressed = false;
						menuPreventDefault = false;
						forceRefreshScreen = applock_stopTimer() || forceRefreshScreen;
						break;
					}
					/* Combo menu jeux (configurable via Saves/.parameters) */
					if (app_tryGameUnlock(ev.code))
						break;
					switch (ev.code) {
						case HW_BTN_POWER :
							startPowerPressed = false;
							break;
						case HW_BTN_LEFT :
							if (time_wait()) {
								app_previous();
							}
							break;
						case HW_BTN_RIGHT :
							if (time_wait()) {
								app_next();
							}
							break;
						case HW_BTN_UP :
							if (time_wait()) {
								app_up();
							}
							break;
						case HW_BTN_DOWN :
							if (time_wait()) {
								app_down();
							}
							break;
						case HW_BTN_A :
						case HW_BTN_B :
							if (time_wait()) {
								if (app_ok())
									telmi_launch_rom(app_getLaunchConsoleId(),
											 app_getLaunchRomPath());
							}
							break;
						case HW_BTN_Y :
						case HW_BTN_X :
							if (time_wait()) {
								app_home();
							}
							break;
						case HW_BTN_L1 :
							if (!isMenuPressed && time_wait()) {
								app_randomChoice();
							}
							break;
						case HW_BTN_L2 :
							if (!isMenuPressed && time_wait()) {
								app_randomStory();
							}
							break;
						case HW_BTN_R1 :
						case HW_BTN_R2 :
						case HW_BTN_SELECT :
						case HW_BTN_SELECT_ALT :
							/* pas d'action carrousel hors combo */
							break;
					}

					if (isMenuPressed) {
						switch (ev.code) {
							case HW_BTN_L2 :
							case HW_BTN_VOLUME_DOWN :
								forceRefreshScreen = app_brightness_down();
								applock_stopTimer();
								menuPreventDefault = true;
								break;
							case HW_BTN_R2 :
							case HW_BTN_VOLUME_UP :
								forceRefreshScreen = app_brightness_up();
								applock_stopTimer();
								menuPreventDefault = true;
								break;
							default:
								break;
						}
					}
					break;

				case REPEAT:
					if (applock_isLocked() || isMenuPressed)
						break;
					autosleep_keepAwake();
					if (ev.code == HW_BTN_VOLUME_DOWN && !ignore_vol_down)
						forceRefreshScreen = app_volume_down();
					else if (ev.code == HW_BTN_VOLUME_UP && !ignore_vol_up)
						forceRefreshScreen = app_volume_up();
					break;

				default:
					break;
			}
		}

		if (forceRefreshScreen) {
			app_forceRefreshScreen();
		}
	}

exit_loop:
	app_save();
	display_setScreen(true);
	video_audio_quit();
	system_shutdown();
	return EXIT_SUCCESS;
}
