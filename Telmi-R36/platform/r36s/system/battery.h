#ifndef BATTERY_H__
#define BATTERY_H__

#include <dirent.h>
#include <stdio.h>
#include <string.h>
#include <stdbool.h>
#include <stdlib.h>

/* ArkOS4Clone / RK817 : ne pas dependre de /tmp/percBat (batmon). */

static int r36s_bat_read_int(const char *path)
{
	FILE *fp;
	int v = -1;

	fp = fopen(path, "r");
	if (!fp)
		return -1;
	if (fscanf(fp, "%d", &v) != 1)
		v = -1;
	fclose(fp);
	return v;
}

static int r36s_bat_from_voltage(int raw)
{
	double v;

	if (raw > 100000)
		v = raw / 1000000.0; /* uV */
	else
		v = raw / 1000.0; /* mV */
	if (v < 3.30)
		return 1;
	if (v > 4.18)
		return 100;
	return (int)((v - 3.30) / (4.18 - 3.30) * 99.0 + 1.5);
}

static void r36s_bat_write_perc(int pct)
{
	FILE *fp;

	if (pct < 0)
		pct = 0;
	if (pct > 100)
		pct = 100;
	fp = fopen("/tmp/percBat", "w");
	if (!fp)
		return;
	fprintf(fp, "%d", pct);
	fclose(fp);
}

int battery_getPercentage(void)
{
	static const char *caps[] = {
		"/sys/class/power_supply/battery/capacity",
		"/sys/class/power_supply/rk817-battery/capacity",
		NULL
	};
	DIR *d;
	struct dirent *e;
	char path[256];
	int i, pct, uv;

	for (i = 0; caps[i]; i++) {
		pct = r36s_bat_read_int(caps[i]);
		if (pct >= 1 && pct <= 100) {
			r36s_bat_write_perc(pct);
			return pct;
		}
	}

	d = opendir("/sys/class/power_supply");
	if (d) {
		while ((e = readdir(d)) != NULL) {
			if (e->d_name[0] == '.')
				continue;
			snprintf(path, sizeof(path),
				 "/sys/class/power_supply/%s/type", e->d_name);
			{
				FILE *tf = fopen(path, "r");
				char typ[32] = {0};
				if (tf) {
					if (fgets(typ, sizeof(typ), tf) == NULL)
						typ[0] = '\0';
					fclose(tf);
				}
				if (typ[0] && strncmp(typ, "Battery", 7) != 0 &&
				    strncmp(typ, "Unknown", 7) != 0)
					continue;
			}
			snprintf(path, sizeof(path),
				 "/sys/class/power_supply/%s/capacity", e->d_name);
			pct = r36s_bat_read_int(path);
			if (pct >= 1 && pct <= 100) {
				closedir(d);
				r36s_bat_write_perc(pct);
				return pct;
			}
			snprintf(path, sizeof(path),
				 "/sys/class/power_supply/%s/voltage_now", e->d_name);
			uv = r36s_bat_read_int(path);
			if (uv > 2500) {
				closedir(d);
				pct = r36s_bat_from_voltage(uv);
				r36s_bat_write_perc(pct);
				return pct;
			}
		}
		closedir(d);
	}

	pct = r36s_bat_read_int("/tmp/percBat");
	if (pct >= 0 && pct <= 100)
		return pct;
	return 0;
}

bool battery_isCharging(void)
{
	FILE *fp;
	char buf[32];
	int on;

	fp = fopen("/sys/class/power_supply/battery/status", "r");
	if (fp) {
		if (fgets(buf, sizeof(buf), fp)) {
			fclose(fp);
			return strncmp(buf, "Charging", 8) == 0;
		}
		fclose(fp);
	}
	on = r36s_bat_read_int("/sys/class/power_supply/ac/online");
	if (on < 0)
		on = r36s_bat_read_int("/sys/class/power_supply/usb/online");
	return on == 1;
}

bool battery_hasChanged(int ticks, int *out_percentage)
{
	int p;

	(void)ticks;
	p = battery_getPercentage();
	if (p != *out_percentage) {
		*out_percentage = p;
		return true;
	}
	return false;
}

#endif
