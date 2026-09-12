#ifndef STORYTELLER_BATTERY__
#define STORYTELLER_BATTERY__

#include "system/battery.h"
#include "SDL2/SDL.h"

static int app_battery_percentage = -1;
static Uint32 app_battery_next_ms;

static int app_battery_getPercentage(void)
{
	Uint32 now = SDL_GetTicks();

	/* Horloge RTC de la console souvent figee : ne pas utiliser time(). */
	if (app_battery_percentage < 0 || now >= app_battery_next_ms) {
		app_battery_next_ms = now + 5000;
		app_battery_percentage = battery_getPercentage();
		if (app_battery_percentage < 0)
			app_battery_percentage = 0;
		if (app_battery_percentage > 100)
			app_battery_percentage = 100;
	}
	return app_battery_percentage;
}

#endif
