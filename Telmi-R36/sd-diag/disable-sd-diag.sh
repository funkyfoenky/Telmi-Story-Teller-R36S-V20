#!/usr/bin/env bash
# Supprime le flag TELMI-SD-DIAG sur BOOT. Linux / macOS.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../scripts/telmi-sd-common.sh
. "$DIR/../scripts/telmi-sd-common.sh"

echo ""
echo " Telmi V30 - Désactiver SD DIAG"
echo " ==============================="

BOOT_ROOT="${1:-}"
if [[ -z "$BOOT_ROOT" ]]; then
	BOOT_ROOT="$(telmi_resolve_boot_root || true)"
fi
if [[ -z "$BOOT_ROOT" || ! -d "$BOOT_ROOT" ]]; then
	echo "ERREUR : volume BOOT introuvable. Passez le chemin :"
	echo "  $0 /Volumes/BOOT"
	exit 1
fi

flag="$BOOT_ROOT/TELMI-SD-DIAG"
if [[ ! -w "$BOOT_ROOT" && -e "$flag" ]]; then
	if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
		exec sudo env PATH="$PATH" bash "$0" "$BOOT_ROOT"
	fi
	echo "ERREUR : $BOOT_ROOT non inscriptible"
	exit 1
fi
if [[ -e "$flag" ]]; then
	rm -f "$flag"
	echo " Supprimé -> $flag"
else
	echo " Déjà absent : $flag"
fi
echo " Boot Telmi normal au prochain démarrage."
echo ""
