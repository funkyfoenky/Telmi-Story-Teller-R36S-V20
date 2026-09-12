#!/usr/bin/env bash
# Crée le flag TELMI-SD-DIAG sur le volume BOOT (carte OS). Linux / macOS.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../scripts/telmi-sd-common.sh
. "$DIR/../scripts/telmi-sd-common.sh"

echo ""
echo " Telmi V30 - Activer SD DIAG"
echo " ============================"
echo " Volume BOOT = partition FAT de la carte OS (Image, DTB, TELMI-REV.txt)."
echo ""

BOOT_ROOT="${1:-}"
if [[ -z "$BOOT_ROOT" ]]; then
	BOOT_ROOT="$(telmi_resolve_boot_root || true)"
fi
if [[ -z "$BOOT_ROOT" || ! -d "$BOOT_ROOT" ]]; then
	echo "ERREUR : volume BOOT introuvable. Passez le chemin :"
	echo "  $0 /Volumes/BOOT"
	echo "  $0 /media/\$USER/BOOT"
	exit 1
fi

flag="$BOOT_ROOT/TELMI-SD-DIAG"
if [[ ! -w "$BOOT_ROOT" ]]; then
	if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
		exec sudo env PATH="$PATH" bash "$0" "$BOOT_ROOT"
	fi
	echo "ERREUR : $BOOT_ROOT non inscriptible"
	exit 1
fi
: > "$flag"
echo " Flag OK -> $flag"

rev="$BOOT_ROOT/TELMI-REV.txt"
if [[ -f "$rev" ]]; then
	r="$(tr -d '[:space:]' < "$rev")"
	echo " TELMI-REV = $r"
	case "$r" in
		[vV]30*) ;;
		*)
			echo " WARN: REV n'est pas v30* — le diag sera ignoré au boot."
			echo " Lancez Select-Telmi-REV.sh -> v30-panel4 avant de tester."
			;;
	esac
else
	echo " WARN: TELMI-REV.txt absent — Select-Telmi-REV.sh requis."
fi

echo ""
echo " Prêt. Éjectez la SD OS, mettez le contenu à gauche, boot."
echo " Après extinction : lisez BOOT/telmi-sd-diag-VERDICT.txt"
echo ""
