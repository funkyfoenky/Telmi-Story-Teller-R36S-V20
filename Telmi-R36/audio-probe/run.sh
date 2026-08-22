#!/bin/sh
# Telmi V30 — sonde audio minimale
# Lancee si /telmi/AUDIO-PROBE ou /boot/TELMI-AUDIO-PROBE existe.
# Log : /telmi/logs/audio-probe.log (+ miroir /tmp)
#
# Chaque etape ~STEP_SEC secondes : change mixer/GPIO, joue tone.wav.
# Couleurs ecran (fbcolor) = code etape — noter la couleur si un son sort.

set -eu

PROBE_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
LOG_DIR=/telmi/logs
LOG="$LOG_DIR/audio-probe.log"
TONE="$PROBE_DIR/tone.wav"
FBCOLOR="$PROBE_DIR/fbcolor"
STEP_SEC="${AUDIO_PROBE_STEP_SEC:-8}"

mkdir -p "$LOG_DIR" 2>/dev/null || true
: >"$LOG" 2>/dev/null || LOG=/tmp/audio-probe.log

log() {
	_ts="$(date '+%H:%M:%S' 2>/dev/null || echo '?')"
	echo "[probe $_ts] $*" | tee -a "$LOG"
}

fb() {
	# r g b (0-255)
	if [ -x "$FBCOLOR" ]; then
		"$FBCOLOR" "$1" "$2" "$3" 2>/dev/null || true
	fi
}

wait_alsa() {
	_i=0
	while [ "$_i" -lt 20 ]; do
		[ -e /dev/snd/controlC0 ] && return 0
		sleep 1
		_i=$((_i + 1))
	done
	return 1
}

dump_env() {
	log "=== ENV ==="
	log "uname: $(uname -a 2>/dev/null || true)"
	log "PROBE_DIR=$PROBE_DIR"
	ls -la /dev/snd 2>&1 | while read -r L; do log "snd: $L"; done
	ls -la /proc/asound 2>&1 | while read -r L; do log "asound: $L"; done
	amixer -c 0 scontents 2>&1 | while read -r L; do log "amixer: $L"; done
	amixer -c 0 cget name='Playback Path' 2>&1 | while read -r L; do log "path: $L"; done
	for c in /sys/class/gpio/gpiochip*; do
		[ -e "$c" ] || continue
		log "gpiochip: $(basename "$c") base=$(cat "$c/base" 2>/dev/null) ngpio=$(cat "$c/ngpio" 2>/dev/null) label=$(cat "$c/label" 2>/dev/null)"
	done
}

set_path() {
	_p="$1"
	amixer -c 0 cset name='Playback Path' "$_p" 2>&1 | while read -r L; do log "cset Path $_p: $L"; done
	amixer -c 0 sset Playback 100% unmute 2>/dev/null || true
	amixer -c 0 sset DAC 100% unmute 2>/dev/null || true
	amixer -c 0 sset Headphone 100% unmute 2>/dev/null || true
	amixer -c 0 sset Speaker 100% unmute 2>/dev/null || true
}

play_tone() {
	_sec="$1"
	if [ ! -f "$TONE" ]; then
		log "WARN: pas de tone.wav"
		sleep "$_sec"
		return 0
	fi
	_end=$(( $(date +%s) + _sec ))
	while [ "$(date +%s)" -lt "$_end" ]; do
		aplay -D default -q "$TONE" 2>>"$LOG" || {
			log "aplay FAIL (voir log)"
			break
		}
	done
}

# Export GPIO as output and set value. Logs busy/errors.
gpio_set() {
	_num="$1"
	_val="$2"
	_dir="/sys/class/gpio/gpio${_num}"
	if [ ! -d "$_dir" ]; then
		echo "$_num" >/sys/class/gpio/export 2>/tmp/gpio-exp.err || {
			log "gpio ${_num}: export FAIL $(cat /tmp/gpio-exp.err 2>/dev/null)"
			return 1
		}
		sleep 1
	fi
	echo out >"$_dir/direction" 2>/tmp/gpio-dir.err || {
		log "gpio ${_num}: direction FAIL $(cat /tmp/gpio-dir.err 2>/dev/null)"
		return 1
	}
	echo "$_val" >"$_dir/value" 2>/tmp/gpio-val.err || {
		log "gpio ${_num}: value FAIL $(cat /tmp/gpio-val.err 2>/dev/null)"
		return 1
	}
	log "gpio ${_num} = ${_val} OK (read=$(cat "$_dir/value" 2>/dev/null))"
	return 0
}

gpio_release() {
	_num="$1"
	[ -d "/sys/class/gpio/gpio${_num}" ] || return 0
	echo "$_num" >/sys/class/gpio/unexport 2>/dev/null || true
}

step() {
	_name="$1"
	_r="$2"
	_g="$3"
	_b="$4"
	shift 4
	log "======== STEP: $_name ========"
	fb "$_r" "$_g" "$_b"
	# shellcheck disable=SC2068
	$@
	play_tone "$STEP_SEC"
}

main() {
	log "Telmi audio-probe START"
	echo 0 >/sys/class/graphics/fb0/blank 2>/dev/null || true

	if ! wait_alsa; then
		log "FATAL: pas de card0"
		fb 255 0 0
		sleep 5
		return 1
	fi
	log "ALSA card0 OK"
	dump_env

	if [ ! -f "$TONE" ]; then
		log "FATAL: $TONE manquant"
		fb 255 0 0
		sleep 5
		return 1
	fi

	# --- Phase A : chemins mixer (sans GPIO custom) ---
	step "A1 Path=SPK"           0 180 0   set_path SPK
	step "A2 Path=HP"            0 0 200   set_path HP
	step "A3 Path=SPK_HP"        0 200 200 set_path SPK_HP
	step "A4 Path=RING_SPK"      180 180 0 set_path RING_SPK
	step "A5 Path=RING_SPK_HP"   200 100 0 set_path RING_SPK_HP
	step "A6 Path=HP_NO_MIC"     100 0 200 set_path HP_NO_MIC
	step "A7 Path=RCV"           80 80 80  set_path RCV

	# --- Phase B : forcer GPIO ampli candidats + Path=SPK ---
	# RK3326 typique : gpio0=0..31 gpio1=32..63 gpio2=64..95 gpio3=96..127
	# gpio3.7 (DTB spk-con) = 103
	# gpio2.7 (R1 V30) = 71 — peut etre busy (gamepad)
	# gpio2.6 (L1) = 70
	# gpio3.6 = 102, gpio2.5 = 69, gpio1.7 = 39
	set_path SPK
	for G in 103 102 101 71 70 69 68 39 38; do
		_ok=0
		gpio_set "$G" 1 && _ok=1 || true
		if [ "$_ok" = 1 ]; then
			# nuance de magenta selon pin
			_c=$((50 + G))
			[ "$_c" -gt 255 ] && _c=255
			step "B gpio${G}=1 + SPK" "$_c" 0 "$_c" set_path SPK
			gpio_set "$G" 0 || true
			gpio_release "$G"
		else
			log "skip gpio $G (busy/invalid)"
		fi
	done

	# --- Phase C : Path=SPK_HP + gpio103 high ---
	if gpio_set 103 1; then
		step "C SPK_HP + gpio103=1" 255 255 255 set_path SPK_HP
		gpio_set 103 0 || true
		gpio_release 103
	fi

	# --- Phase D : volume Playback a 255 explicite + SPK ---
	step "D Playback=255 SPK" 0 255 128 sh -c "amixer -c 0 sset Playback 255 unmute; amixer -c 0 cset name='Playback Path' SPK"

	log "======== FIN sonde ========"
	log "Si un son a ete entendu : noter COULEUR ecran + ligne STEP du log."
	fb 40 40 40
	sleep 3
	return 0
}

main "$@"
