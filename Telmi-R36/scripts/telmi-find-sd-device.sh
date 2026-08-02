#!/bin/bash
# Trouve /dev/sdX dont la taille (octets) == $1
set -e
TARGET="${1:?usage: $0 <bytes>}"
DEV=
for d in /dev/sd[a-z] /dev/sd[a-z][a-z]; do
	[ -b "$d" ] || continue
	sz=$(blockdev --getsize64 "$d" 2>/dev/null || echo 0)
	if [ "$sz" = "$TARGET" ]; then
		DEV=$d
		break
	fi
done
if [ -z "$DEV" ]; then
	echo "ERREUR: disque introuvable dans WSL (cible ${TARGET} octets)" >&2
	lsblk -o NAME,SIZE,TYPE,TRAN,MODEL >&2
	exit 2
fi
echo "$DEV"
