#!/bin/sh
# TelmiOS — diagnostic panel AVEC MIPI actif (flag /boot/TELMI-PANEL-DIAG).
# Complement du bootdiag (DSI off) : capture dmesg/panel pendant un vrai test ecran.
#
# Ecrit sur BOOT (Windows) :
#   telmi-panel-diag.log
#   telmi-panel-diag-VERDICT.txt
#   telmi-panic-prev.log  (via telmi-export-pstore.sh au boot suivant si panic)
#
# Ne coupe pas le DSI. Ne force pas l'extinction — le boot Telmi continue en parallele.

set -u

LOG=/boot/telmi-panel-diag.log
VERDICT=/boot/telmi-panel-diag-VERDICT.txt
DT=/sys/firmware/devicetree/base
[ -d "$DT" ] || DT=/proc/device-tree

mkdir -p /boot
mountpoint -q /boot || mount /boot 2>/dev/null || true

: >"$LOG" 2>/dev/null || LOG=/tmp/telmi-panel-diag.log
: >"$LOG"

log() {
	_ts="$(date '+%H:%M:%S' 2>/dev/null || echo '?')"
	_line="[panel-diag $_ts] $*"
	echo "$_line" >>"$LOG" 2>/dev/null || echo "$_line"
	sync 2>/dev/null || true
}

dtstr() {
	_p="$1"
	if [ -f "$_p" ]; then
		tr -d '\0' <"$_p" 2>/dev/null || cat "$_p" 2>/dev/null || echo "?"
	else
		echo "(absent)"
	fi
}

dmesg_panel() {
	dmesg 2>/dev/null | grep -iE 'dsi|mipi|panel|drm|rockchip-drm|dw-mipi|simple-panel|elida|vop|backlight|enable-gpios|error|fail|panic|oops|BUG|Unable' || true
}

log "=== TELMI PANEL-DIAG (MIPI ON) ==="
log "uname: $(uname -a 2>/dev/null || echo ?)"
log "uptime: $(cat /proc/uptime 2>/dev/null || echo ?)"
if [ -f /opt/telmi/telmiVersion/image-version.txt ]; then
	log "image=$(cat /opt/telmi/telmiVersion/image-version.txt) build=$(cat /opt/telmi/telmiVersion/build-id.txt 2>/dev/null)"
fi
log "REV=$(tr -d '\r\n ' </boot/TELMI-REV.txt 2>/dev/null || echo ?)"

log "=== device-tree ==="
log "model=$(dtstr $DT/model)"
log "dsi status=$(dtstr $DT/dsi@ff450000/status 2>/dev/null || echo absent)"
log "panel compatible=$(dtstr $DT/dsi@ff450000/panel@0/compatible 2>/dev/null || echo absent)"
if [ -f "$DT/dsi@ff450000/panel@0/enable-gpios" ]; then
	log "panel enable-gpios: present"
fi

log "=== fb / drm ==="
ls /dev/fb* 2>/dev/null | while read -r _l; do log "  $_l"; done || log "  (pas fb)"
ls /dev/dri/ 2>/dev/null | while read -r _l; do log "  dri: $_l"; done || log "  (pas dri/card)"
if [ -d /sys/class/graphics/fb0 ]; then
	log "fb0=$(cat /sys/class/graphics/fb0/name 2>/dev/null || echo ?)"
fi

log "=== dmesg panel/dsi (snapshot T0) ==="
_dmesg_t0=$(dmesg_panel | tail -n 80)
if [ -z "$_dmesg_t0" ]; then
	log "  (vide)"
else
	echo "$_dmesg_t0" | while read -r _l; do log "  $_l"; done
fi
_panic0=$(dmesg 2>/dev/null | grep -icE 'Kernel panic|Oops|Unhandled fault' || true)
log "panic_oops_hits_T0=$_panic0"

log "=== heartbeat 25s (sync apres chaque tick) ==="
_i=0
while [ "$_i" -lt 25 ]; do
	sleep 1
	_i=$((_i + 1))
	_up=$(awk '{print $1}' /proc/uptime 2>/dev/null || echo ?)
	echo "alive ${_i}s uptime=${_up}" >>"$LOG"
	sync 2>/dev/null || true
done

log "=== dmesg panel/dsi (snapshot T+25s) ==="
_dmesg_t1=$(dmesg_panel | tail -n 120)
if [ -z "$_dmesg_t1" ]; then
	log "  (vide)"
else
	echo "$_dmesg_t1" | while read -r _l; do log "  $_l"; done
fi
_panic1=$(dmesg 2>/dev/null | grep -icE 'Kernel panic|Oops|Unhandled fault' || true)
log "panic_oops_hits_T1=$_panic1"

# Verdict
_dsi_st=$(dtstr "$DT/dsi@ff450000/status" 2>/dev/null)
_has_fb=0
[ -c /dev/fb0 ] 2>/dev/null && _has_fb=1
_has_drm=0
[ -e /dev/dri/card0 ] 2>/dev/null && _has_drm=1

{
	echo "panel_diag=OK"
	echo "rev=$(tr -d '\r\n ' </boot/TELMI-REV.txt 2>/dev/null || echo ?)"
	echo "model=$(dtstr $DT/model)"
	echo "dsi_status=$_dsi_st"
	echo "fb0=$([ "$_has_fb" -eq 1 ] && echo yes || echo no)"
	echo "drm_card=$([ "$_has_drm" -eq 1 ] && echo yes || echo no)"
	echo "panic_hits=$_panic1"
	echo "log=telmi-panel-diag.log"
	echo "note=Si_ce_fichier_existe_userspace_a_demarre_avec_DSI_actif"
	echo "note2=Si_boot_mort_avant_userspace_relire_telmi-panic-prev_log_au_boot_suivant"
} >"$VERDICT" 2>/dev/null || true

sync 2>/dev/null || true
log "=== PANEL-DIAG fin (boot Telmi continue) ==="
exit 0
