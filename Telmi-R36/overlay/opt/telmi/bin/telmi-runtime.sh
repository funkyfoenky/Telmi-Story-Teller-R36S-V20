#!/bin/sh
# TelmiOS runtime R36S

TELMI_ROOT=/opt/telmi
export PATH="$TELMI_ROOT/bin:$PATH"
unset LD_LIBRARY_PATH
export SDL_AUDIODRIVER=alsa

log() { echo "[telmi] $(date '+%H:%M:%S') $*"; }

ensure_content_mounted() {
	if ! mountpoint -q /telmi 2>/dev/null; then
		log "ERREUR : /telmi non monte — Stories/Music indisponibles"
		return 1
	fi
	mkdir -p /telmi/.tmp_update /telmi/Stories /telmi/Music /telmi/Saves/Stories /telmi/logs
	if ! mountpoint -q /telmi/.tmp_update 2>/dev/null; then
		mount --bind /opt/telmi /telmi/.tmp_update 2>/dev/null || true
	fi
	if [ ! -e /telmi/.tmp_update/res/selectStories.png ]; then
		log "WARN : assets UI absents sous /telmi/.tmp_update/res"
	fi
	if [ ! -f /telmi/Saves/.parameters ]; then
		cat > /telmi/Saves/.parameters <<'EOF'
{"audioVolumeStartup":0.5,"audioVolumeMax":1.0,"screenBrightnessStartup":0.4,"screenBrightnessMax":0.8,"screenOnInactivityTime":60,"screenOffInactivityTime":120,"musicInactivityTime":1800,"storyDisplayTiles":true,"storyDisableNightMode":false,"storyDisableTimeline":false,"musicDisableRepeatModes":false,"bootSplashscreen":""}
EOF
	fi
	_nstories=$(find /telmi/Stories -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
	log "Contenu : ${_nstories} histoire(s) sous /telmi/Stories"
	return 0
}

init_display() {
	echo -n "640x480" > /tmp/screen_resolution
	echo -n "283" > /tmp/deviceModel
	[ -c /dev/fb0 ] && echo 0 > /sys/class/graphics/fb0/blank 2>/dev/null
}

# Force Mesa software : panfrost plante sur noyau vendor 5.10 V20
setup_mesa_sw() {
	for d in panfrost_dri.so rockchip_dri.so mali-dp_dri.so; do
		[ -f "/usr/lib/dri/$d" ] && mv -f "/usr/lib/dri/$d" "/usr/lib/dri/$d.disabled" 2>/dev/null
	done
	export MESA_LOADER_DRIVER_OVERRIDE=kms_swrast
	export GALLIUM_DRIVER=softpipe
	export LIBGL_ALWAYS_SOFTWARE=1
	export SDL_RENDER_DRIVER=software
}

run_probe() {
	log "Probe fb0 (sans SDL)"
	sdlprobe-fb 2>&1 || log "sdlprobe-fb echec"
	if [ -f /boot/sdl-steps.log ]; then
		log "--- sdl-steps (fb) ---"
		cat /boot/sdl-steps.log 2>/dev/null
	fi

	setup_mesa_sw
	export SDL_VIDEODRIVER=kmsdrm
	unset SDL_FBDEV
	log "Probe SDL kmsdrm+swrast"
	sdlprobe 2>&1 || log "sdlprobe SDL echec"
	if [ -f /boot/sdl-steps.log ]; then
		log "--- sdl-steps (apres SDL) ---"
		cat /boot/sdl-steps.log 2>/dev/null
	fi
}

run_sdl() {
	_app="$1"
	shift
	setup_mesa_sw
	export SDL_VIDEODRIVER=kmsdrm
	unset SDL_FBDEV
	log "Lancement $_app (SDL_VIDEODRIVER=$SDL_VIDEODRIVER swrast)"
	"$_app" "$@" 2>&1
	_ec=$?
	if [ "$_ec" -eq 0 ]; then
		log "$_app termine OK"
		return 0
	fi
	log "$_app echec (code $_ec)"
	return "$_ec"
}

main() {
	log "Demarrage TelmiOS R36S"
	if [ -f /opt/telmi/telmiVersion/image-version.txt ]; then
		log "Image $(cat /opt/telmi/telmiVersion/image-version.txt) build $(cat /opt/telmi/telmiVersion/build-id.txt 2>/dev/null)"
	fi
	echo "[telmi] runtime pid $$" >> /telmi/logs/runtime.log 2>/dev/null
	init_display

	# Splash immediat (logo PNG sur fb0) — avant le reste
	log "Lancement bootScreen (framebuffer)"
	bootScreen Boot 2>&1 || log "bootScreen ignore"

	ensure_content_mounted || log "WARN : poursuite sans partition TELMI montee"

	rm -f /tmp/.offOrder 2>/dev/null

	batmon &

	cd "$TELMI_ROOT"

	# Probes diag uniquement si /boot/TELMI-DEBUG present
	if [ -f /boot/TELMI-DEBUG ]; then
		log "Mode debug : probes ecran"
		run_probe
		bootScreen Boot 2>&1 || true
	fi

	log "Audio : SDL_AUDIODRIVER=$SDL_AUDIODRIVER"

	# Mode sonde audio V30 : flag sur TELMI (editable Windows) ou BOOT
	if [ -f /telmi/AUDIO-PROBE ] || [ -f /boot/TELMI-AUDIO-PROBE ]; then
		log "MODE AUDIO-PROBE (flag detecte)"
		_probe=""
		[ -x /telmi/audio-probe/run.sh ] && _probe=/telmi/audio-probe/run.sh
		[ -z "$_probe" ] && [ -x /opt/telmi/audio-probe/run.sh ] && _probe=/opt/telmi/audio-probe/run.sh
		if [ -n "$_probe" ]; then
			log "Lancement $_probe"
			"$_probe" 2>&1 | tee -a /telmi/logs/runtime.log 2>/dev/null || "$_probe" 2>&1
			log "audio-probe termine — extinction"
			bootScreen End 2>&1 || true
			poweroff -f 2>/dev/null || halt -f
			exit 0
		fi
		log "WARN: flag AUDIO-PROBE sans run.sh"
	fi

	# Attendre la carte ALSA (probe codec parfois lent / apres gpio)
	_i=0
	while [ "$_i" -lt 15 ]; do
		[ -e /dev/snd/controlC0 ] && break
		sleep 1
		_i=$((_i + 1))
	done
	if [ ! -e /dev/snd/controlC0 ]; then
		log "WARN: pas de /dev/snd/controlC0 apres ${_i}s"
		ls -la /dev/snd 2>&1 | while read -r _l; do log "snd: $_l"; done
	else
		log "ALSA card0 presente"
	fi
	# Playback Path selon /boot/TELMI-REV.txt (image unique multi-REV)
	_play_path=SPK
	_rev=""
	[ -f /boot/TELMI-REV.txt ] && _rev=$(tr -d '[:space:]' </boot/TELMI-REV.txt)
	[ -z "$_rev" ] && [ -f /boot/TELMI-PROFILE.txt ] && _rev=$(tr -d '[:space:]' </boot/TELMI-PROFILE.txt)
	[ -z "$_rev" ] && [ -f /opt/telmi/telmiVersion/profile.txt ] && _rev=$(tr -d '[:space:]' </opt/telmi/telmiVersion/profile.txt)
	case "$_rev" in
		v30*|*panel4*) _play_path=HP ;;
	esac
	[ -f /boot/TELMI-AUDIO-PATH.txt ] && _ap=$(tr -d '[:space:]' </boot/TELMI-AUDIO-PATH.txt) && \
		case "$_ap" in SPK|HP|SPK_HP) _play_path="$_ap" ;; esac
	log "REV=${_rev:-v20} audio_path=$_play_path"
	amixer -c 0 cset name='Playback Path' "$_play_path" 2>/dev/null && log "Playback Path=$_play_path" || log "WARN: Playback Path indisponible"
	amixer -c 0 sset Playback 100% unmute 2>/dev/null || true
	amixer -c 0 sset DAC 100% unmute 2>/dev/null || true
	amixer -c 0 sset Headphone unmute 2>/dev/null || true
	amixer -c 0 sset Speaker unmute 2>/dev/null || true
	amixer -c 0 sget Playback 2>/dev/null || true
	amixer -c 0 cget name='Playback Path' 2>/dev/null || true

	log "Lancement storyTeller"
	run_sdl storyTeller || log "storyTeller echec"

	while true; do
		[ -f /tmp/.offOrder ] && break
		sleep 1
	done

	bootScreen End 2>&1 || true
	poweroff -f 2>/dev/null || halt -f
}

main "$@"
