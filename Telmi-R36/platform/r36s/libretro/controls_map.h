#ifndef TELMI_CONTROLS_MAP_H
#define TELMI_CONTROLS_MAP_H

/**
 * Charge /telmi/config/controls.json (ou /telmi/Saves/.parameters → controls)
 * et remplit une table bouton physique → id libretro (-1 = ignore).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#include "libretro.h"
#include "../system/keymap_hw.h"

#define TELMI_CTRL_PATH_PRIMARY   "/telmi/config/controls.json"
#define TELMI_CTRL_PATH_PARAMS    "/telmi/Saves/.parameters"

enum {
	CTRL_UP = 0,
	CTRL_DOWN,
	CTRL_LEFT,
	CTRL_RIGHT,
	CTRL_A,
	CTRL_B,
	CTRL_X,
	CTRL_Y,
	CTRL_L1,
	CTRL_R1,
	CTRL_L2,
	CTRL_R2,
	CTRL_START,
	CTRL_SELECT,
	CTRL_COUNT
};

static const char *ctrl_phys_names[CTRL_COUNT] = {
	"UP", "DOWN", "LEFT", "RIGHT",
	"A", "B", "X", "Y",
	"L1", "R1", "L2", "R2",
	"START", "SELECT"
};

/* map[phys] = RETRO_DEVICE_ID_JOYPAD_* or -1 */
static int ctrl_map[CTRL_COUNT];

static int ctrl_retro_from_name(const char *v)
{
	if (!v || !v[0] || strcmp(v, "null") == 0 || strcmp(v, "none") == 0)
		return -1;
	if (strcmp(v, "UP") == 0) return RETRO_DEVICE_ID_JOYPAD_UP;
	if (strcmp(v, "DOWN") == 0) return RETRO_DEVICE_ID_JOYPAD_DOWN;
	if (strcmp(v, "LEFT") == 0) return RETRO_DEVICE_ID_JOYPAD_LEFT;
	if (strcmp(v, "RIGHT") == 0) return RETRO_DEVICE_ID_JOYPAD_RIGHT;
	if (strcmp(v, "A") == 0) return RETRO_DEVICE_ID_JOYPAD_A;
	if (strcmp(v, "B") == 0) return RETRO_DEVICE_ID_JOYPAD_B;
	if (strcmp(v, "X") == 0) return RETRO_DEVICE_ID_JOYPAD_X;
	if (strcmp(v, "Y") == 0) return RETRO_DEVICE_ID_JOYPAD_Y;
	if (strcmp(v, "L") == 0 || strcmp(v, "L1") == 0) return RETRO_DEVICE_ID_JOYPAD_L;
	if (strcmp(v, "R") == 0 || strcmp(v, "R1") == 0) return RETRO_DEVICE_ID_JOYPAD_R;
	if (strcmp(v, "L2") == 0) return RETRO_DEVICE_ID_JOYPAD_L2;
	if (strcmp(v, "R2") == 0) return RETRO_DEVICE_ID_JOYPAD_R2;
	if (strcmp(v, "START") == 0) return RETRO_DEVICE_ID_JOYPAD_START;
	if (strcmp(v, "SELECT") == 0) return RETRO_DEVICE_ID_JOYPAD_SELECT;
	return -1;
}

static int ctrl_phys_from_name(const char *k)
{
	int i;
	for (i = 0; i < CTRL_COUNT; i++) {
		if (strcmp(k, ctrl_phys_names[i]) == 0)
			return i;
	}
	return -1;
}

static void ctrl_set_defaults(void)
{
	int i;
	for (i = 0; i < CTRL_COUNT; i++)
		ctrl_map[i] = ctrl_retro_from_name(
			(i == CTRL_L1) ? "L" : (i == CTRL_R1) ? "R" : ctrl_phys_names[i]);
}

/* Applique les paires "KEY":"VAL" trouvees dans un bloc JSON (objet) */
static void ctrl_apply_object(const char *obj, size_t len)
{
	const char *p = obj;
	const char *end = obj + len;

	while (p < end) {
		const char *k0, *k1, *v0, *v1;
		char key[32], val[32];
		int pi, ri;
		size_t kn, vn;

		while (p < end && *p != '"')
			p++;
		if (p >= end)
			break;
		k0 = ++p;
		while (p < end && *p != '"')
			p++;
		if (p >= end)
			break;
		k1 = p++;
		while (p < end && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r' || *p == ':'))
			p++;
		if (p >= end || *p != '"')
			continue;
		v0 = ++p;
		while (p < end && *p != '"')
			p++;
		if (p >= end)
			break;
		v1 = p++;

		kn = (size_t)(k1 - k0);
		vn = (size_t)(v1 - v0);
		if (kn >= sizeof(key) || vn >= sizeof(val))
			continue;
		memcpy(key, k0, kn);
		key[kn] = 0;
		memcpy(val, v0, vn);
		val[vn] = 0;

		pi = ctrl_phys_from_name(key);
		if (pi < 0)
			continue;
		ri = ctrl_retro_from_name(val);
		ctrl_map[pi] = ri;
	}
}

/* Trouve le contenu de l'objet JSON apres "name" : { ... } (profondeur 1+) */
static int ctrl_find_object(const char *json, const char *name, const char **out, size_t *out_len)
{
	char pattern[64];
	const char *hit, *p;
	int depth;

	snprintf(pattern, sizeof(pattern), "\"%s\"", name);
	hit = strstr(json, pattern);
	if (!hit)
		return 0;
	p = hit + strlen(pattern);
	while (*p && *p != '{')
		p++;
	if (*p != '{')
		return 0;
	*out = p + 1;
	depth = 1;
	p++;
	while (*p && depth > 0) {
		if (*p == '{')
			depth++;
		else if (*p == '}')
			depth--;
		p++;
	}
	if (depth != 0)
		return 0;
	*out_len = (size_t)((p - 1) - *out);
	return 1;
}

static char *ctrl_read_file(const char *path, size_t *len_out)
{
	FILE *f;
	long sz;
	char *buf;

	f = fopen(path, "rb");
	if (!f)
		return NULL;
	if (fseek(f, 0, SEEK_END) != 0) {
		fclose(f);
		return NULL;
	}
	sz = ftell(f);
	if (sz <= 0 || sz > 512 * 1024) {
		fclose(f);
		return NULL;
	}
	rewind(f);
	buf = (char *)malloc((size_t)sz + 1);
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
	buf[sz] = 0;
	if (len_out)
		*len_out = (size_t)sz;
	return buf;
}

static void ctrl_load_from_json(const char *json, const char *system_id)
{
	const char *obj;
	size_t obj_len;
	const char *controls_root = json;
	size_t controls_len = strlen(json);

	/* Si c'est .parameters, extraire d'abord "controls" */
	if (ctrl_find_object(json, "controls", &obj, &obj_len)) {
		/* Isoler temporairement : on travaille sur une copie du sous-objet */
		char *sub = (char *)malloc(obj_len + 3);
		if (sub) {
			sub[0] = '{';
			memcpy(sub + 1, obj, obj_len);
			sub[obj_len + 1] = '}';
			sub[obj_len + 2] = 0;
			controls_root = sub;
			controls_len = obj_len + 2;
			(void)controls_len;
			if (ctrl_find_object(controls_root, "default", &obj, &obj_len))
				ctrl_apply_object(obj, obj_len);
			if (system_id && system_id[0] &&
			    ctrl_find_object(controls_root, "systems", &obj, &obj_len)) {
				char *sysblk = (char *)malloc(obj_len + 3);
				if (sysblk) {
					const char *sobj;
					size_t slen;
					sysblk[0] = '{';
					memcpy(sysblk + 1, obj, obj_len);
					sysblk[obj_len + 1] = '}';
					sysblk[obj_len + 2] = 0;
					if (ctrl_find_object(sysblk, system_id, &sobj, &slen))
						ctrl_apply_object(sobj, slen);
					free(sysblk);
				}
			}
			free(sub);
			return;
		}
	}

	if (ctrl_find_object(controls_root, "default", &obj, &obj_len))
		ctrl_apply_object(obj, obj_len);
	if (system_id && system_id[0] &&
	    ctrl_find_object(controls_root, "systems", &obj, &obj_len)) {
		char *sysblk = (char *)malloc(obj_len + 3);
		if (sysblk) {
			const char *sobj;
			size_t slen;
			sysblk[0] = '{';
			memcpy(sysblk + 1, obj, obj_len);
			sysblk[obj_len + 1] = '}';
			sysblk[obj_len + 2] = 0;
			if (ctrl_find_object(sysblk, system_id, &sobj, &slen))
				ctrl_apply_object(sobj, slen);
			free(sysblk);
		}
	}
}

static void controls_init(const char *system_id)
{
	char *buf;

	ctrl_set_defaults();

	buf = ctrl_read_file(TELMI_CTRL_PATH_PRIMARY, NULL);
	if (!buf)
		buf = ctrl_read_file(TELMI_CTRL_PATH_PARAMS, NULL);
	if (buf) {
		ctrl_load_from_json(buf, system_id);
		free(buf);
		fprintf(stderr, "[telmi_lr] controls loaded for %s\n",
			system_id ? system_id : "?");
	} else {
		fprintf(stderr, "[telmi_lr] controls defaults (no config file)\n");
	}
}

static int controls_hw_to_index(unsigned code)
{
	if (code == HW_BTN_UP) return CTRL_UP;
	if (code == HW_BTN_DOWN) return CTRL_DOWN;
	if (code == HW_BTN_LEFT) return CTRL_LEFT;
	if (code == HW_BTN_RIGHT) return CTRL_RIGHT;
	if (code == HW_BTN_A) return CTRL_A;
	if (code == HW_BTN_B) return CTRL_B;
	if (code == HW_BTN_X) return CTRL_X;
	if (code == HW_BTN_Y) return CTRL_Y;
	if (code == HW_BTN_L1) return CTRL_L1;
	if (code == HW_BTN_R1) return CTRL_R1;
	if (code == HW_BTN_L2) return CTRL_L2;
	if (code == HW_BTN_R2) return CTRL_R2;
	if (HW_BTN_IS_START(code)) return CTRL_START;
	if (HW_BTN_IS_SELECT(code)) return CTRL_SELECT;
	return -1;
}

static void controls_apply_hw(unsigned code, int pressed, void (*set_btn_fn)(unsigned, int))
{
	int idx = controls_hw_to_index(code);
	int rid;
	if (idx < 0)
		return;
	rid = ctrl_map[idx];
	if (rid >= 0)
		set_btn_fn((unsigned)rid, pressed);
}

static void controls_apply_hat_x(int value, void (*set_btn_fn)(unsigned, int))
{
	int left = ctrl_map[CTRL_LEFT];
	int right = ctrl_map[CTRL_RIGHT];
	if (left >= 0)
		set_btn_fn((unsigned)left, value < 0);
	if (right >= 0)
		set_btn_fn((unsigned)right, value > 0);
}

static void controls_apply_hat_y(int value, void (*set_btn_fn)(unsigned, int))
{
	int up = ctrl_map[CTRL_UP];
	int down = ctrl_map[CTRL_DOWN];
	if (up >= 0)
		set_btn_fn((unsigned)up, value < 0);
	if (down >= 0)
		set_btn_fn((unsigned)down, value > 0);
}

#endif
