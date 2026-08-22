#!/bin/sh
# Wrapper : si flag AUDIO-PROBE, lance la sonde ; sinon storyTeller.real
export PATH="/opt/telmi/bin:$PATH"
if [ -f /telmi/AUDIO-PROBE ] || [ -f /boot/TELMI-AUDIO-PROBE ]; then
	echo "[telmi] MODE AUDIO-PROBE"
	if [ -x /telmi/audio-probe/run.sh ]; then
		exec /telmi/audio-probe/run.sh
	fi
	if [ -x /opt/telmi/audio-probe/run.sh ]; then
		exec /opt/telmi/audio-probe/run.sh
	fi
	echo "[telmi] ERREUR: audio-probe/run.sh introuvable"
	sleep 5
	poweroff -f 2>/dev/null || halt -f
	exit 1
fi
exec /opt/telmi/bin/storyTeller.real "$@"
