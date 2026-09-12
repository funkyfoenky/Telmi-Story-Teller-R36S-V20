#!/bin/sh
# TelmiOS — diagnostic boot headless (Y3506 / panel inconnu)
# Declenche si /boot/TELMI-BOOT-DIAG present.
# Ecrit sur BOOT (lisible Windows) meme sans ecran.
#
# But : savoir si le noyau demarre quand le panel MIPI est coupe.
# Si ce log apparait -> Linux vit ; le probleme est l'ecran/DTB panel.
# Si aucun fichier apres boot -> U-Boot/noyau meurt avant userspace.

set -eu

LOG=/boot/telmi-boot-diag.log
VERDICT=/boot/telmi-boot-diag-VERDICT.txt
DT=/sys/firmware/devicetree/base
[ -d "$DT" ] || DT=/proc/device-tree

mkdir -p /boot
mountpoint -q /boot || mount /boot 2>/dev/null || true

: >"$LOG" 2>/dev/null || LOG=/tmp/telmi-boot-diag.log
: >"$LOG"

log() {
	_ts="$(date '+%H:%M:%S' 2>/dev/null || echo '?')"
	echo "[boot-diag $_ts] $*" | tee -a "$LOG" 2>/dev/null || echo "[boot-diag $_ts] $*"
}

dtstr() {
	_p="$1"
	if [ -f "$_p" ]; then
		tr -d '\0' <"$_p" 2>/dev/null || cat "$_p" 2>/dev/null || echo "?"
	else
		echo "(absent)"
	fi
}

log "=== TELMI BOOT-DIAG start ==="
log "uname: $(uname -a 2>/dev/null || echo ?)"
log "uptime: $(cat /proc/uptime 2>/dev/null || echo ?)"

if [ -f /opt/telmi/telmiVersion/image-version.txt ]; then
	log "image=$(cat /opt/telmi/telmiVersion/image-version.txt) build=$(cat /opt/telmi/telmiVersion/build-id.txt 2>/dev/null)"
fi
log "REV=$(tr -d '\r\n ' </boot/TELMI-REV.txt 2>/dev/null || echo ?)"
log "AUDIO=$(tr -d '\r\n ' </boot/TELMI-AUDIO-PATH.txt 2>/dev/null || echo ?)"

log "=== device-tree model / compatible ==="
log "model=$(dtstr $DT/model)"
log "compatible=$(dtstr $DT/compatible)"

log "=== dsi / panel status ==="
for _n in dsi@ff450000 dsi@ff450000/panel@0; do
	_st="$DT/$_n/status"
	if [ -f "$_st" ]; then
		log "$_n status=$(dtstr $_st)"
	elif [ -d "$DT/$_n" ]; then
		log "$_n present (no status prop = okay)"
	else
		log "$_n ABSENT"
	fi
done
if [ -f "$DT/dsi@ff450000/panel@0/compatible" ]; then
	log "panel compatible=$(dtstr $DT/dsi@ff450000/panel@0/compatible)"
fi
if [ -f "$DT/dsi@ff450000/panel@0/reset-gpios" ]; then
	log "panel reset-gpios present (bin)"
fi

log "=== framebuffer / drm ==="
ls -la /dev/fb* /dev/dri/* 2>/dev/null | while read -r _l; do log "  $_l"; done || log "  (pas de fb/dri)"
if [ -d /sys/class/graphics/fb0 ]; then
	log "fb0 name=$(cat /sys/class/graphics/fb0/name 2>/dev/null || echo ?)"
	log "fb0 virtual_size=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null || echo ?)"
fi
ls /sys/class/drm 2>/dev/null | while read -r _l; do log "  drm: $_l"; done || true

log "=== mmc / block ==="
ls -la /dev/mmcblk* 2>/dev/null | while read -r _l; do log "  $_l"; done || log "  (pas mmcblk)"
for _h in /sys/class/mmc_host/mmc*; do
	[ -d "$_h" ] || continue
	_cards=0
	for _c in "$_h"/mmc*; do
		[ -d "$_c" ] && _cards=$((_cards + 1))
	done
	log "  host $(basename "$_h") cards=$_cards"
done

log "=== input ==="
ls /dev/input 2>/dev/null | while read -r _l; do log "  input: $_l"; done || true
if [ -d /sys/class/input ]; then
	for _e in /sys/class/input/event*; do
		[ -e "$_e/device/name" ] || continue
		log "  $(basename "$_e")=$(cat "$_e/device/name" 2>/dev/null)"
	done
fi

log "=== audio ==="
ls /dev/snd 2>/dev/null | while read -r _l; do log "  snd: $_l"; done || log "  (pas snd)"
amixer -c 0 scontrols 2>/dev/null | head -n 20 | while read -r _l; do log "  amixer: $_l"; done || true

log "=== dmesg panel/dsi/drm/mmc (tail) ==="
if command -v dmesg >/dev/null 2>&1; then
	dmesg 2>/dev/null | grep -iE 'dsi|mipi|panel|drm|rockchip-drm|dw-mipi|simple-panel|elida|st7703|kd35|error|panic|oops|vop' | tail -n 100 | while read -r _l; do
		log "  dmesg: $_l"
	done
	_pc=$(dmesg 2>/dev/null | grep -icE 'panic|oops|Unhandled' || true)
	log "panic_oops_hits=$_pc"
else
	log "dmesg absent"
fi

log "=== mounts ==="
awk '{print}' /proc/mounts 2>/dev/null | while read -r _l; do log "  mnt: $_l"; done

# Heartbeat : prouve que userspace a tourne N secondes
log "=== heartbeat 8s ==="
_i=0
while [ "$_i" -lt 8 ]; do
	sleep 1
	_i=$((_i + 1))
	echo "alive ${_i}s $(cat /proc/uptime 2>/dev/null | awk '{print $1}')" >>"$LOG"
done
log "heartbeat OK"

KERNEL_OK=1
PANEL_HINT="dsi_disabled_or_unknown"
if [ -f "$DT/dsi@ff450000/status" ]; then
	_ds=$(dtstr "$DT/dsi@ff450000/status")
	case "$_ds" in
		disabled|Disabled) PANEL_HINT="dsi_disabled_volontaire" ;;
		okay|Ok|OK|"") PANEL_HINT="dsi_okay_probe_a_verifier_dmesg" ;;
		*) PANEL_HINT="dsi_status=$_ds" ;;
	esac
fi

{
	echo "kernel_userspace=OK"
	echo "rev=$(tr -d '\r\n ' </boot/TELMI-REV.txt 2>/dev/null || echo ?)"
	echo "model=$(dtstr $DT/model)"
	echo "panel_hint=$PANEL_HINT"
	echo "log=telmi-boot-diag.log"
	echo "recommend=si_ce_fichier_existe_Linux_demarre_tester_matrice_DTB_panel"
	echo "next=y3506-t-panel4 puis y3506-t-init puis y3506-t-timings"
} >"$VERDICT" 2>/dev/null || true

sync
log "=== BOOT-DIAG fin — extinction ==="
sync
poweroff -f 2>/dev/null || halt -f
exit 0
