#!/bin/sh
# Exporte le journal panic/oops du boot PRECEDENT (ramoops/pstore) sur BOOT.
# Tourne des le montage /boot — utile quand le probe MIPI tue le noyau avant userspace.

set -eu

OUT=/boot/telmi-panic-prev.log
PS=/sys/fs/pstore

mountpoint -q /boot 2>/dev/null || exit 0
[ -d "$PS" ] || exit 0

_found=0
{
	echo "=== telmi pstore export $(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo ?) ==="
	echo "rev=$(tr -d '\r\n ' </boot/TELMI-REV.txt 2>/dev/null || echo ?)"
	for _f in "$PS"/*; do
		[ -e "$_f" ] || continue
		[ -f "$_f" ] || continue
		_base=$(basename "$_f")
		case "$_base" in
			*.txt|*ramoops*|*console*|*dmesg*|*panic*|*oops*)
				;;
			*)
				continue
				;;
		esac
		_found=1
		echo "--- $_base ---"
		cat "$_f" 2>/dev/null || true
		echo ""
	done
	if [ "$_found" -eq 0 ]; then
		echo "(aucun fichier pstore lisible — pas de panic enregistre au boot precedent)"
	fi
} >"$OUT" 2>/dev/null || exit 0

sync 2>/dev/null || true
exit 0
