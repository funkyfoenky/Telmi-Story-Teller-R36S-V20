#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

/* Moniteur batterie minimal R36S (sans PMIC Miyoo) */
int main(void)
{
	FILE *fp;
	int pct = 100;

	for (;;) {
		fp = fopen("/sys/class/power_supply/battery/capacity", "r");
		if (fp) {
			if (fscanf(fp, "%d", &pct) != 1)
				pct = 100;
			fclose(fp);
		}
		fp = fopen("/tmp/percBat", "w");
		if (fp) {
			fprintf(fp, "%d", pct);
			fclose(fp);
		}
		sleep(30);
	}
	return 0;
}
