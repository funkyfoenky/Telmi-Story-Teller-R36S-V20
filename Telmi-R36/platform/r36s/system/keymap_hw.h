#ifndef KEYMAP_HW_H__
#define KEYMAP_HW_H__

#include <linux/input.h>

/* Mapping R36S V20 (gpio-keys / joypad) */
#define HW_BTN_UP         BTN_DPAD_UP
#define HW_BTN_DOWN       BTN_DPAD_DOWN
#define HW_BTN_LEFT       BTN_DPAD_LEFT
#define HW_BTN_RIGHT      BTN_DPAD_RIGHT
/* R36S V20 : silkscreen style Xbox (A=bas/South, B=droite/East) */
#define HW_BTN_A          BTN_SOUTH
#define HW_BTN_B          BTN_EAST
#define HW_BTN_X          BTN_NORTH
#define HW_BTN_Y          BTN_WEST
#define HW_BTN_L1         BTN_TL
#define HW_BTN_R1         BTN_TR
#define HW_BTN_L2         BTN_TL2
#define HW_BTN_R2         BTN_TR2
/* V20 : Select/Start = BTN_SELECT/BTN_START (314/315). Anciens DTB : TRIGGER_HAPPY* */
#define HW_BTN_SELECT     BTN_SELECT
#define HW_BTN_SELECT_ALT BTN_TRIGGER_HAPPY1
#define HW_BTN_START      BTN_START
#define HW_BTN_START_ALT  BTN_TRIGGER_HAPPY3
#define HW_BTN_START_ALT2 BTN_TRIGGER_HAPPY2 /* clones : Start = HAPPY2, pas FN */
#define HW_BTN_MENU       BTN_TRIGGER_HAPPY4
#define HW_BTN_FN         BTN_TRIGGER_HAPPY5
#define HW_BTN_FN_ALT2    BTN_TRIGGER_HAPPY6
#define HW_BTN_FN_ALT3    KEY_FN
#define HW_BTN_FN_ALT4    KEY_MENU
#define HW_BTN_FN_ALT5    BTN_MODE
#define HW_BTN_POWER      KEY_POWER
#define HW_BTN_VOLUME_UP  KEY_VOLUMEUP
#define HW_BTN_VOLUME_DOWN KEY_VOLUMEDOWN

static inline int HW_BTN_IS_MENU(unsigned int code)
{
	return code == HW_BTN_MENU || code == HW_BTN_FN ||
	       code == HW_BTN_FN_ALT2 ||
	       code == HW_BTN_FN_ALT3 || code == HW_BTN_FN_ALT4 ||
	       code == HW_BTN_FN_ALT5;
}

static inline int HW_BTN_IS_START(unsigned int code)
{
	return code == HW_BTN_START || code == HW_BTN_START_ALT ||
	       code == HW_BTN_START_ALT2;
}

static inline int HW_BTN_IS_SELECT(unsigned int code)
{
	return code == HW_BTN_SELECT || code == HW_BTN_SELECT_ALT;
}

#endif
