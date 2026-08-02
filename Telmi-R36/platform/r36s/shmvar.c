#include "shmvar/shmvar.h"

#include <stddef.h>

static int stub_values[MONITOR_VALUE_MAX];

int InitKeyShm(KeyShmInfo *info)
{
	if (info == NULL)
		return -1;
	info->id = KEYMON_SHMKEYID;
	info->addr = stub_values;
	return 0;
}

int SetKeyShm(KeyShmInfo *info, MonitorValue key, int value)
{
	(void)info;
	if (key < 0 || key >= MONITOR_VALUE_MAX)
		return -1;
	stub_values[key] = value;
	return 0;
}

int GetKeyShm(KeyShmInfo *info, MonitorValue key)
{
	(void)info;
	if (key < 0 || key >= MONITOR_VALUE_MAX)
		return 0;
	return stub_values[key];
}

int UninitKeyShm(KeyShmInfo *info)
{
	(void)info;
	return 0;
}
