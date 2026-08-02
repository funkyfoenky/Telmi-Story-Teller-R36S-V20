#!/usr/bin/env bash
# Lit telmi-runtime.log depuis une carte SD ou une image .img (WSL).
set -euo pipefail

IMG=""
DEV=""
MNT="/tmp/telmi-sd-read"

usage() {
	echo "Usage:"
	echo "  $0 --sd /dev/sdX          (carte SD dans le lecteur PC)"
	echo "  $0 --img /chemin/image.img"
	echo ""
	echo "Sous Windows : lancez via WSL. La partition BOOT (FAT) contient telmi-runtime.log"
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--sd) DEV="$2"; shift 2 ;;
		--img) IMG="$2"; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) echo "Option inconnue: $1"; usage; exit 1 ;;
	esac
done

cleanup() {
	umount "$MNT" 2>/dev/null || true
	if [[ -n "$DEV" && -b "${DEV}p1" ]]; then
		:
	elif [[ -n "$LOOP" ]]; then
		losetup -d "$LOOP" 2>/dev/null || true
	fi
}
trap cleanup EXIT

mkdir -p "$MNT"

if [[ -n "$IMG" ]]; then
	[[ -f "$IMG" ]] || { echo "Image introuvable: $IMG"; exit 1; }
	LOOP="$(losetup --show -f -P "$IMG")"
	sleep 1
	mount "${LOOP}p1" "$MNT"
elif [[ -n "$DEV" ]]; then
	[[ -b "${DEV}p1" || -b "${DEV}1" ]] || { echo "Peripherique invalide: $DEV"; exit 1; }
	if [[ -b "${DEV}p1" ]]; then
		mount "${DEV}p1" "$MNT"
	else
		mount "${DEV}1" "$MNT"
	fi
else
	echo "Precisez --sd ou --img"
	usage
	exit 1
fi

LOG="$MNT/telmi-runtime.log"
README="$MNT/TELMI-README.txt"

if [[ -f "$LOG" ]]; then
	echo "=== $LOG ==="
	cat "$LOG"
else
	echo "Pas de telmi-runtime.log sur la partition BOOT."
	echo "Contenu de la partition BOOT :"
	ls -la "$MNT"
fi

if [[ -f "$README" ]]; then
	echo ""
	echo "=== $README ==="
	cat "$README"
fi
