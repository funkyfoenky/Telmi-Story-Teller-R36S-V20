#!/usr/bin/env bash
# Prépare une carte CONTENU Telmi (slot gauche R36S) — FAT32 label TELMI.
# Équivalent Linux/macOS de prepare-content-sd.ps1.
#
# Usage :
#   sudo bash scripts/prepare-content-sd.sh
#   sudo bash scripts/prepare-content-sd.sh /dev/sdX --yes
#   sudo bash scripts/prepare-content-sd.sh disk4 --yes
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=telmi-sd-common.sh
. "$SCRIPT_DIR/telmi-sd-common.sh"

DEV=""
AUTO_YES=0

usage() {
	sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
	exit "${1:-0}"
}

for _a in "$@"; do
	case "$_a" in -h|--help) usage 0 ;; esac
done
telmi_need_root "$@"

while [[ $# -gt 0 ]]; do
	case "$1" in
		-h|--help) usage 0 ;;
		--yes|-y) AUTO_YES=1; shift ;;
		/dev/*|disk[0-9]*|sd[a-z]*|mmcblk*|nvme*)
			DEV="$(telmi_normalize_dev "$1")"
			shift
			;;
		*)
			echo "Argument inconnu : $1"
			usage 1
			;;
	esac
done

echo ""
echo "============================================================"
echo " TelmiOS - Prépare carte CONTENU (slot gauche) ($TELMI_OS)"
echo "============================================================"
echo " Cette carte est pour Stories/Music/Saves + Telmi Sync."
echo " L'OS reste sur la SD du slot DROIT (flash --os-only)."
echo ""

if [[ -z "$DEV" ]]; then
	telmi_list_removable
	telmi_print_disks || exit 1
	echo ""
	printf "Numéro (ou Q) : "
	read -r sel
	sel="$(printf '%s' "$sel" | tr -d '[:space:]')"
	case "$sel" in
		Q|q) echo "Annulé."; exit 0 ;;
		[1-9]|[1-9][0-9]) ;;
		*) echo "ERREUR : choix invalide"; exit 1 ;;
	esac
	if [[ "$sel" -lt 1 || "$sel" -gt $TELMI_DISK_COUNT ]]; then
		echo "ERREUR : choix invalide"
		exit 1
	fi
	DEV="${TELMI_DEV_LIST[$sel]}"
else
	DEV="$(telmi_normalize_dev "$DEV")"
	telmi_dev_exists "$DEV" || { echo "ERREUR : $DEV introuvable"; exit 1; }
fi
telmi_assert_whole_disk

if telmi_is_system_disk "$DEV" && [[ "${FORCE_SYSTEM_DISK:-0}" != "1" ]]; then
	echo "ERREUR : $DEV ressemble à un disque système."
	exit 1
fi

DISK_BYTES="$(telmi_disk_bytes "$DEV")"
echo " Cible : $DEV ($(telmi_fmt_gb "$DISK_BYTES"))"
echo " ATTENTION : toutes les partitions seront effacées."

if [[ "$AUTO_YES" != "1" ]]; then
	printf "Tapez PREPARE pour confirmer : "
	read -r c
	[[ "$c" = "PREPARE" ]] || { echo "Annulé."; exit 0; }
fi

init_content_disk() {
	telmi_umount_all
	sleep 0.5
	if [[ "$TELMI_OS" = "macos" ]]; then
		echo "==> diskutil eraseDisk FAT32 TELMI (MBR)..."
		diskutil eraseDisk FAT32 TELMI MBRFormat "${DEV#/dev/}"
		return 0
	fi
	telmi_need_fat32
	echo "==> Table MBR + partition FAT32 unique..."
	if command -v wipefs >/dev/null 2>&1; then
		wipefs -a "$DEV" >/dev/null 2>&1 || true
	fi
	dd if=/dev/zero of="$DEV" bs=1M count=4 status=none 2>/dev/null || true
	if command -v parted >/dev/null 2>&1; then
		parted -s "$DEV" mklabel msdos
		parted -s "$DEV" mkpart primary fat32 1MiB 100%
	else
		telmi_need_sgdisk
		sgdisk --zap-all "$DEV" >/dev/null
		sgdisk -o "$DEV" >/dev/null
		sgdisk -n 1:1MiB:0 -t 1:0700 -c 1:TELMI "$DEV" >/dev/null
		echo "  (parted absent : GPT 1 partition au lieu de MBR)"
	fi
	telmi_reread_pt
	wait_parts 1
	telmi_format_fat32 "$(part_path 1)" TELMI
}

init_content_disk

mnt=""
if [[ "$TELMI_OS" = "macos" ]]; then
	p="$(part_path 1)"
	mnt="$(diskutil info "$p" 2>/dev/null | awk -F ': *' '/Mount Point:/ { print $2; exit }')"
	if [[ -z "$mnt" || "$mnt" = "Not applicable" || ! -d "$mnt" ]]; then
		mnt="/Volumes/TELMI"
	fi
	if [[ ! -d "$mnt" ]]; then
		mnt="$(mktemp -d /tmp/telmi-content-XXXXXX)"
		telmi_mount_fat "$p" "$mnt"
	fi
	seed_telmi_content_tree "$mnt" 1
	sync
else
	seed_telmi_content "$(part_path 1)" 1
fi

echo ""
echo " Carte contenu prête (label TELMI)."
echo " Insérez-la dans le slot GAUCHE de la R36S."
echo ""
