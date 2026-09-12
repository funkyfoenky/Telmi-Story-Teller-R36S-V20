#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int read_int_file(const char *path, int *out)
{
	FILE *fp = fopen(path, "r");
	int v;

	if (!fp)
		return -1;
	if (fscanf(fp, "%d", &v) != 1) {
		fclose(fp);
		return -1;
	}
	fclose(fp);
	*out = v;
	return 0;
}

static int pct_from_voltage(int raw)
{
	double v = (raw > 100000) ? raw / 1000000.0 : raw / 1000.0;

	if (v < 3.30)
		return 1;
	if (v > 4.18)
		return 100;
	return (int)((v - 3.30) / (4.18 - 3.30) * 99.0 + 1.5);
}

static int read_battery_pct(void)
{
	DIR *d;
	struct dirent *e;
	char path[256];
	int pct, uv;

	if (read_int_file("/sys/class/power_supply/battery/capacity", &pct) == 0 &&
	    pct >= 1 && pct <= 100)
		return pct;

	d = opendir("/sys/class/power_supply");
	if (!d)
		return 0;
	while ((e = readdir(d)) != NULL) {
		if (e->d_name[0] == '.')
			continue;
		snprintf(path, sizeof(path), "/sys/class/power_supply/%s/capacity",
			 e->d_name);
		if (read_int_file(path, &pct) == 0 && pct >= 1 && pct <= 100) {
			closedir(d);
			return pct;
		}
		snprintf(path, sizeof(path), "/sys/class/power_supply/%s/voltage_now",
			 e->d_name);
		if (read_int_file(path, &uv) == 0 && uv > 2500) {
			closedir(d);
			return pct_from_voltage(uv);
		}
	}
	closedir(d);
	return 0;
}

int main(void)
{
	FILE *fp;
	int pct = 0;

	for (;;) {
		pct = read_battery_pct();
		fp = fopen("/tmp/percBat", "w");
		if (fp) {
			fprintf(fp, "%d", pct);
			fclose(fp);
		}
		sleep(15);
	}
	return 0;
}
