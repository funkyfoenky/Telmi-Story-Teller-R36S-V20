/* Profil matériel TelmiOS — runtime via /boot/TELMI-REV.txt (image unique multi-REV).
 * Plus de quirks compile-time V20/V30 : un seul binaire. */
#ifndef TELMI_REV_H
#define TELMI_REV_H

#include <stdio.h>
#include <string.h>
#include <ctype.h>

#define TELMI_REV_MAX 64

static char telmi_rev_cached[TELMI_REV_MAX];
static int telmi_rev_loaded;
static char telmi_audio_override[16];
static int telmi_audio_override_checked;

static int telmi_rev_read_file(const char *path, char *out, size_t outsz)
{
	FILE *fp;
	size_t n;
	char *p;

	fp = fopen(path, "r");
	if (!fp)
		return 0;
	if (!fgets(out, (int)outsz, fp)) {
		fclose(fp);
		out[0] = '\0';
		return 0;
	}
	fclose(fp);

	/* trim debut */
	p = out;
	while (*p && isspace((unsigned char)*p))
		p++;
	if (p != out)
		memmove(out, p, strlen(p) + 1);

	/* coupe au premier separateur / newline */
	p = out;
	while (*p && *p != '\n' && *p != '\r' && *p != ' ' && *p != '\t')
		p++;
	*p = '\0';

	/* trim fin deja coupe */
	n = strlen(out);
	return n > 0;
}

/* Charge le REV une fois. Priorite : TELMI-REV.txt > TELMI-PROFILE.txt > profile.txt > v20 */
static void telmi_rev_load(void)
{
	char buf[TELMI_REV_MAX];

	if (telmi_rev_loaded)
		return;
	telmi_rev_loaded = 1;
	telmi_rev_cached[0] = '\0';

	if (telmi_rev_read_file("/boot/TELMI-REV.txt", buf, sizeof(buf))) {
		strncpy(telmi_rev_cached, buf, TELMI_REV_MAX - 1);
		telmi_rev_cached[TELMI_REV_MAX - 1] = '\0';
		return;
	}
	if (telmi_rev_read_file("/boot/TELMI-PROFILE.txt", buf, sizeof(buf))) {
		strncpy(telmi_rev_cached, buf, TELMI_REV_MAX - 1);
		telmi_rev_cached[TELMI_REV_MAX - 1] = '\0';
		return;
	}
	if (telmi_rev_read_file("/opt/telmi/telmiVersion/profile.txt", buf, sizeof(buf))) {
		strncpy(telmi_rev_cached, buf, TELMI_REV_MAX - 1);
		telmi_rev_cached[TELMI_REV_MAX - 1] = '\0';
		return;
	}
	strncpy(telmi_rev_cached, "v20", TELMI_REV_MAX - 1);
}

static const char *telmi_rev_id(void)
{
	telmi_rev_load();
	return telmi_rev_cached[0] ? telmi_rev_cached : "v20";
}

/* true si REV famille V30 (panel4, etc.) */
static int telmi_rev_is_v30(void)
{
	const char *id = telmi_rev_id();
	if (strncmp(id, "v30", 3) == 0)
		return 1;
	if (strstr(id, "panel4") != NULL)
		return 1;
	return 0;
}

/* ALSA Playback Path HP : V30 Panel4 + Y3506 (routing DarkOS = casque). */
static int telmi_rev_uses_hp(void)
{
	const char *id = telmi_rev_id();
	if (telmi_rev_is_v30())
		return 1;
	if (strncmp(id, "y3506", 5) == 0)
		return 1;
	return 0;
}

/* ALSA Playback Path : HP sur V30 Panel4 / Y3506, SPK sinon.
 * Surcharge : /boot/TELMI-AUDIO-PATH.txt (SPK | HP | SPK_HP). */
static const char *telmi_audio_path(void)
{
	if (!telmi_audio_override_checked) {
		telmi_audio_override_checked = 1;
		telmi_audio_override[0] = '\0';
		if (telmi_rev_read_file("/boot/TELMI-AUDIO-PATH.txt",
					telmi_audio_override,
					sizeof(telmi_audio_override))) {
			if (strcmp(telmi_audio_override, "HP") != 0 &&
			    strcmp(telmi_audio_override, "SPK") != 0 &&
			    strcmp(telmi_audio_override, "SPK_HP") != 0)
				telmi_audio_override[0] = '\0';
		}
	}
	if (telmi_audio_override[0])
		return telmi_audio_override;
	return telmi_rev_uses_hp() ? "HP" : "SPK";
}

/* Sur V30, zed_keyboard est un fantome VOL- ; sur V20 c'est le vrai volume. */
static int telmi_ignore_zed_keyboard(void)
{
	return telmi_rev_is_v30();
}

#endif /* TELMI_REV_H */
