#!/usr/bin/env bash
# Configure la REV sur le volume BOOT (FAT) — Linux / macOS.
# Équivalent de Select-Telmi-REV.ps1 (aucun rootfs).
#
# Usage :
#   bash scripts/select-telmi-rev.sh
#   bash scripts/select-telmi-rev.sh /Volumes/BOOT
#   bash scripts/select-telmi-rev.sh --rev v30-panel4
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=telmi-sd-common.sh
. "$SCRIPT_DIR/telmi-sd-common.sh"

BOOT_ROOT=""
REV_ID=""

usage() {
	sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
	exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		-h|--help) usage 0 ;;
		--rev)
			REV_ID="${2:-}"
			[[ -n "$REV_ID" ]] || { echo "ERREUR : --rev sans id"; exit 1; }
			shift 2
			;;
		*)
			if [[ -d "$1" ]]; then
				BOOT_ROOT="$1"
				shift
			else
				echo "Argument inconnu : $1"
				usage 1
			fi
			;;
	esac
done

echo ""
echo " TelmiOS - Sélection REV (post-flash)"
echo " ===================================="
echo ""

if [[ -z "$BOOT_ROOT" ]]; then
	BOOT_ROOT="$(telmi_resolve_boot_root || true)"
fi

if [[ -z "$BOOT_ROOT" || ! -f "$BOOT_ROOT/revs.json" ]]; then
	echo "Volume BOOT introuvable (revs.json)."
	echo " Branchez la SD OS, montez la partition BOOT, ou passez le chemin :"
	echo "   $0 /Volumes/BOOT"
	echo "   $0 /media/$USER/BOOT"
	if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
		echo ""
		echo " Nouvelle tentative avec sudo..."
		exec sudo env PATH="$PATH" bash "$0" ${REV_ID:+--rev "$REV_ID"} "$@"
	fi
	exit 1
fi

echo " BOOT = $BOOT_ROOT"

if [[ ! -w "$BOOT_ROOT" ]]; then
	echo " BOOT non inscriptible — élévation sudo..."
	exec sudo env PATH="$PATH" bash "$0" "$BOOT_ROOT" ${REV_ID:+--rev "$REV_ID"}
fi

parse_revs() {
	local json="$1"
	if command -v python3 >/dev/null 2>&1 && python3 --version >/dev/null 2>&1; then
		python3 - "$json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
print("META\t%s\t%s" % (c.get("default", ""), c.get("active_dtb", "rf3536k3ka.dtb")))
for r in c.get("revs") or []:
    print("REV\t%s\t%s\t%s\t%s" % (
        r.get("id", ""),
        r.get("label", ""),
        r.get("dtb", ""),
        r.get("audio_path") or "SPK",
    ))
PY
		return 0
	fi
	if command -v jq >/dev/null 2>&1; then
		jq -r '
			"META\t\(.default // "")\t\(.active_dtb // "rf3536k3ka.dtb")",
			(.revs[] | "REV\t\(.id)\t\(.label)\t\(.dtb)\t\(.audio_path // "SPK")")
		' "$json"
		return 0
	fi
	# POSIX awk (macOS sans python3 / jq) — revs.json un champ par ligne
	awk '
		function jstr(key,    n, p, i) {
			n = split($0, p, "\"")
			for (i = 1; i <= n; i++) if (p[i] == key) return p[i+2]
			return ""
		}
		/"revs"/ {
			if (active == "") active = "rf3536k3ka.dtb"
			print "META\t" def "\t" active
			inrevs = 1
			next
		}
		!inrevs && /"default"/ { def = jstr("default"); next }
		!inrevs && /"active_dtb"/ { active = jstr("active_dtb"); next }
		inrevs && /"id"/ { id = jstr("id"); next }
		inrevs && /"label"/ { label = jstr("label"); next }
		inrevs && /"dtb"/ { dtb = jstr("dtb"); next }
		inrevs && /"audio_path"/ { audio = jstr("audio_path"); next }
		inrevs && /}/ && id != "" {
			if (audio == "") audio = "SPK"
			print "REV\t" id "\t" label "\t" dtb "\t" audio
			id = ""; label = ""; dtb = ""; audio = ""
		}
	' "$json"
}

DEFAULT_ID=""
ACTIVE_DTB="rf3536k3ka.dtb"
REV_IDS=()
REV_LABELS=()
REV_DTBS=()
REV_AUDIOS=()
REV_N=0

while IFS="$(printf '\t')" read -r kind a b c d; do
	case "$kind" in
		META)
			DEFAULT_ID="$a"
			ACTIVE_DTB="$b"
			[[ -n "$ACTIVE_DTB" ]] || ACTIVE_DTB="rf3536k3ka.dtb"
			;;
		REV)
			REV_N=$((REV_N + 1))
			REV_IDS[$REV_N]="$a"
			REV_LABELS[$REV_N]="$b"
			REV_DTBS[$REV_N]="$c"
			REV_AUDIOS[$REV_N]="$d"
			;;
	esac
done < <(parse_revs "$BOOT_ROOT/revs.json")

if [[ "$REV_N" -eq 0 ]]; then
	echo "ERREUR : revs.json invalide (pas de revs)"
	exit 1
fi

idx=0
if [[ -n "$REV_ID" ]]; then
	i=1
	while [[ $i -le $REV_N ]]; do
		if [[ "${REV_IDS[$i]}" = "$REV_ID" ]]; then
			idx=$i
			break
		fi
		i=$((i + 1))
	done
	[[ "$idx" -gt 0 ]] || { echo "ERREUR : REV inconnue : $REV_ID"; exit 1; }
else
	echo " REVs disponibles :"
	i=1
	while [[ $i -le $REV_N ]]; do
		mark=""
		[[ "${REV_IDS[$i]}" = "$DEFAULT_ID" ]] && mark=" (défaut image)"
		echo "  [$i] ${REV_IDS[$i]} - ${REV_LABELS[$i]}$mark"
		i=$((i + 1))
	done
	echo ""
	printf "Numéro de REV : "
	read -r sel
	sel="$(printf '%s' "$sel" | tr -d '[:space:]')"
	case "$sel" in
		[1-9]|[1-9][0-9]) ;;
		*) echo "ERREUR : choix invalide"; exit 1 ;;
	esac
	idx="$sel"
	if [[ "$idx" -lt 1 || "$idx" -gt $REV_N ]]; then
		echo "ERREUR : choix invalide"
		exit 1
	fi
fi

rev_id="${REV_IDS[$idx]}"
dtb_rel="${REV_DTBS[$idx]}"
audio="${REV_AUDIOS[$idx]}"
dtb_src="$BOOT_ROOT/$dtb_rel"

if [[ ! -f "$dtb_src" ]]; then
	echo "ERREUR : DTB manquant : $dtb_src"
	exit 1
fi

active_dst="$BOOT_ROOT/$ACTIVE_DTB"

echo ""
echo " Application REV=$rev_id"
cp -f "$dtb_src" "$active_dst"
printf '%s' "$rev_id" > "$BOOT_ROOT/TELMI-REV.txt"
printf '%s' "$rev_id" > "$BOOT_ROOT/TELMI-PROFILE.txt"
printf '%s' "$audio" > "$BOOT_ROOT/TELMI-AUDIO-PATH.txt"
sync

echo "  DTB    : $ACTIVE_DTB <- $dtb_rel"
echo "  REV    : $rev_id"
echo "  Audio  : $audio"
echo ""
echo " OK. Éjectez la SD et bootez la console."
echo ""
