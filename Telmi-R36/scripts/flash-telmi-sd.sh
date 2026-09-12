#!/usr/bin/env bash
# Flash TelmiOS sur une carte SD — Linux et macOS (équivalent de flash-telmi-sd-win.ps1).
#
# Usage :
#   sudo bash scripts/flash-telmi-sd.sh
#   sudo bash scripts/flash-telmi-sd.sh /dev/sdX --from-image --yes
#   sudo bash scripts/flash-telmi-sd.sh disk4 --os-only
#   sudo bash scripts/flash-telmi-sd.sh /dev/disk4 --expand
#
# Modes :
#   --from-image   (défaut) écrit LATEST.img puis recrée TELMI sur tout l'espace restant
#   --os-only      flash OS sans expand p3 (dual-SD : contenu sur slot gauche)
#   --expand       recrée seulement p3 TELMI (après Balena Etcher / flash partiel)
#   --full         Linux/WSL : reconstruit depuis rootfs.tar (développeurs)
#
# Dépendances :
#   Linux : gdisk (sgdisk), dosfstools, util-linux
#   macOS : brew install gptfdisk   (newfs_msdos est natif)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=telmi-sd-common.sh
. "$SCRIPT_DIR/telmi-sd-common.sh"

VERSION="$(tr -d '[:space:]' < "$TELMI_R36/VERSION" 2>/dev/null || echo "0.0.0")"
BUILD_ID="$(date '+%Y%m%d-%H%M')"
ROOTFS_TAR="$OUTPUT_DIR/rootfs.tar"
ROOT_PART_SIZE_MB="${ROOT_PART_SIZE_MB:-1536}"
BOOT_RESERVED_SECTORS=32768
BOOT_PART_SECTORS=1024000
ROOT_PART_START=1056768

DEV=""
MODE="from-image"
AUTO_YES=0
WORKING_IMG=""

usage() {
	sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
	exit "${1:-0}"
}

for _a in "$@"; do
	case "$_a" in -h|--help) usage 0 ;; esac
done
telmi_need_root "$@"

while [[ $# -gt 0 ]]; do
	case "$1" in
		-h|--help) usage 0 ;;
		--expand) MODE="expand"; shift ;;
		--from-image|--latest) MODE="from-image"; shift ;;
		--os-only) MODE="os-only"; shift ;;
		--full) MODE="full"; shift ;;
		--yes|-y) AUTO_YES=1; shift ;;
		--image)
			WORKING_IMG="${2:-}"
			[[ -n "$WORKING_IMG" ]] || { echo "ERREUR : --image sans chemin"; exit 1; }
			shift 2
			;;
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

pick_disk() {
	local sel n
	telmi_list_removable
	if [[ -n "$DEV" ]]; then
		DEV="$(telmi_normalize_dev "$DEV")"
		telmi_dev_exists "$DEV" || { echo "ERREUR : $DEV introuvable"; exit 1; }
		return 0
	fi
	echo ""
	telmi_print_disks || exit 1
	echo ""
	printf "Numéro dans la liste (ou Q) : "
	read -r sel
	sel="$(printf '%s' "$sel" | tr -d '[:space:]')"
	case "$sel" in
		Q|q) echo "Annulé."; exit 0 ;;
		[1-9]|[1-9][0-9]) ;;
		*) echo "ERREUR : choix invalide"; exit 1 ;;
	esac
	n="$sel"
	if [[ "$n" -lt 1 || "$n" -gt $TELMI_DISK_COUNT ]]; then
		echo "ERREUR : choix invalide"
		exit 1
	fi
	DEV="${TELMI_DEV_LIST[$n]}"
}

pick_disk
telmi_assert_whole_disk

DISK_BYTES="$(telmi_disk_bytes "$DEV")"
DISK_SECTORS=$((DISK_BYTES / 512))
DISK_GB="$(awk -v b="$DISK_BYTES" 'BEGIN { printf "%.1f", b/1000/1000/1000 }')"
DISK_GIB="$(awk -v b="$DISK_BYTES" 'BEGIN { printf "%.2f", b/1024/1024/1024 }')"

if [[ "$DISK_BYTES" -lt $((3 * 1024 * 1024 * 1024)) ]]; then
	echo "ERREUR : disque trop petit ($DISK_GIB GiB) — minimum ~3 GiB"
	exit 1
fi

if telmi_is_system_disk "$DEV"; then
	echo "ERREUR : $DEV ressemble à un disque système."
	echo "         Si c'est bien la SD : FORCE_SYSTEM_DISK=1 $0 $DEV ..."
	if [[ "${FORCE_SYSTEM_DISK:-0}" != "1" ]]; then
		exit 1
	fi
fi

ROOT_PART_SECTORS=$((ROOT_PART_SIZE_MB * 1024 * 1024 / 512))
ROOT_PART_END=$((ROOT_PART_START + ROOT_PART_SECTORS - 1))
TELMI_PART_START=$((ROOT_PART_END + 1))
TELMI_PART_END=$((DISK_SECTORS - 34))
BOOT_PART_END=$((BOOT_RESERVED_SECTORS + BOOT_PART_SECTORS - 1))
TELMI_SIZE_MB=$(( (TELMI_PART_END - TELMI_PART_START + 1) * 512 / 1024 / 1024 ))

echo ""
echo "============================================================"
echo " TelmiOS flash SD ($TELMI_OS)"
echo " Device     : $DEV"
echo " Capacité   : ${DISK_GB} Go (~${DISK_GIB} GiB)"
echo " Mode       : $MODE"
echo " Version    : $VERSION ($BUILD_ID)"
echo "============================================================"
echo " ATTENTION : le contenu du disque sera modifié."

if [[ "$AUTO_YES" != "1" ]]; then
	echo ""
	printf "Tapez FLASH pour confirmer : "
	read -r confirm
	[[ "$confirm" = "FLASH" ]] || { echo "Annulé."; exit 0; }
fi

flash_from_image() {
	local img img_bytes
	img="$(resolve_latest_telmi_img)" || {
		echo "ERREUR : aucune image telmi-r36-*.img dans $OUTPUT_DIR"
		echo "         Placez LATEST.txt + l'image, ou passez --image /chemin.img"
		exit 1
	}
	WORKING_IMG="$img"
	img_bytes="$(telmi_file_size "$WORKING_IMG")"
	if [[ "$DISK_BYTES" -lt "$img_bytes" ]]; then
		echo "ERREUR : SD trop petite pour $(basename "$WORKING_IMG") ($(telmi_fmt_gb "$img_bytes"))"
		exit 1
	fi
	echo "==> Source image TelmiOS : $WORKING_IMG"
	telmi_write_image "$WORKING_IMG" 
	telmi_repair_gpt
}

write_boot_extlinux() {
	local part="$1"
	local mnt
	mnt="$(mktemp -d /tmp/telmi-boot-XXXXXX)"
	telmi_mount_fat "$part" "$mnt"
	mkdir -p "$mnt/extlinux"
	cat > "$mnt/extlinux/extlinux.conf" <<'EOF'
LABEL ArkOS
  LINUX /Image
  FDT /rf3536k3ka.dtb
  INITRD /uInitrd
  APPEND earlyprintk console=ttyFIQ0 rw root=/dev/mmcblk1p2 rootfstype=ext4 loglevel=7 init=/sbin/init rootwait rootdelay=2 fsck.repair=yes fbcon=rotate:0 quiet splash plymouth.ignore-serial-consoles consoleblank=0

LABEL ArkOS-mmc0
  LINUX /Image
  FDT /rf3536k3ka.dtb
  INITRD /uInitrd
  APPEND earlyprintk console=ttyFIQ0 rw root=/dev/mmcblk0p2 rootfstype=ext4 loglevel=7 init=/sbin/init rootwait rootdelay=2 fsck.repair=yes fbcon=rotate:0 quiet splash plymouth.ignore-serial-consoles consoleblank=0
EOF
	printf '%s' "${VERSION}" > "$mnt/TELMI-VERSION.txt"
	cat > "$mnt/TELMI-README.txt" <<EOF
TelmiOS R36S — partition BOOT
Version : ${VERSION}
Build   : ${BUILD_ID}
Flash   : flash-telmi-sd.sh (${MODE})
EOF
	sync
	if [[ "$TELMI_OS" = "macos" ]]; then
		diskutil unmount "$mnt" >/dev/null 2>&1 || umount "$mnt" 2>/dev/null || true
	else
		umount "$mnt"
	fi
	rmdir "$mnt" 2>/dev/null || true
}

# --- mode développeur Linux (rootfs.tar) ---
sync_telmi_bins_from_latest_img() {
	local root_mnt="$1"
	local img="" tmp root_img mnt tools_dir fuse2fs skip count p2_start p2_end
	tools_dir="$TELMI_R36/.tools"
	fuse2fs=""
	img="$(resolve_latest_telmi_img 2>/dev/null || true)"
	[[ -n "$img" && -f "$img" ]] || return 0

	if [[ -x "$tools_dir/fuse2fs" ]]; then
		fuse2fs="$tools_dir/fuse2fs"
		export LD_LIBRARY_PATH="$tools_dir/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
	elif command -v fuse2fs >/dev/null 2>&1; then
		fuse2fs="$(command -v fuse2fs)"
	else
		echo "==> (info) fuse2fs absent — rootfs.tar seul (pas de sync LATEST)"
		return 0
	fi

	skip="$ROOT_PART_START"
	count="$ROOT_PART_SECTORS"
	if command -v parted >/dev/null 2>&1; then
		p2_start="$(parted -s "$img" unit s print 2>/dev/null | awk '/^ 2 / { gsub(/s/,"",$2); print $2; exit }')"
		p2_end="$(parted -s "$img" unit s print 2>/dev/null | awk '/^ 2 / { gsub(/s/,"",$3); print $3; exit }')"
		if [[ -n "${p2_start:-}" && -n "${p2_end:-}" ]]; then
			skip="$p2_start"
			count=$((p2_end - p2_start + 1))
		fi
	fi

	echo "==> Sync opt/telmi depuis $(basename "$img")..."
	tmp="$(mktemp -d /tmp/telmi-flash-sync-XXXXXX)"
	root_img="$tmp/root.ext4"
	mnt="$tmp/mnt"
	mkdir -p "$mnt"
	dd if="$img" of="$root_img" bs=512 skip="$skip" count="$count" status=none
	"$fuse2fs" -o fakeroot,ro "$root_img" "$mnt" || {
		rm -rf "$tmp"
		return 0
	}
	if [[ -d "$mnt/opt/telmi" ]]; then
		mkdir -p "$root_mnt/opt/telmi"
		rsync -rl "$mnt/opt/telmi/" "$root_mnt/opt/telmi/"
		chmod +x "$root_mnt/opt/telmi/bin/"* 2>/dev/null || true
	fi
	fusermount -u "$mnt" 2>/dev/null || umount "$mnt" 2>/dev/null || true
	rm -rf "$tmp"
}

flash_full() {
	local cand latest
	if [[ "$TELMI_OS" != "linux" ]]; then
		echo "ERREUR : --full (rootfs.tar) est réservé à Linux / WSL."
		echo "         Sur macOS, utilisez --from-image avec une .img déjà assemblée."
		exit 1
	fi
	if [[ -z "$WORKING_IMG" || ! -f "$WORKING_IMG" ]]; then
		for cand in \
			"$OUTPUT_DIR/Base.img" \
			"$TELMI_R36/../R36S-Clone_V20_2025-05-08.img" \
			"$TELMI_R36/../output/r36s-v20-helloworld-light.img"
		do
			if [[ -f "$cand" ]]; then
				WORKING_IMG="$cand"
				break
			fi
		done
	fi
	[[ -n "$WORKING_IMG" && -f "$WORKING_IMG" ]] || { echo "ERREUR : pas d'image BOOT (Base.img / clone V20)"; exit 1; }
	[[ -f "$ROOTFS_TAR" ]] || { echo "ERREUR : $ROOTFS_TAR manquant — lancez build-telmi-rootfs.sh"; exit 1; }
	command -v mkfs.ext4 >/dev/null 2>&1 || { echo "ERREUR : mkfs.ext4 requis (e2fsprogs)"; exit 1; }
	command -v parted >/dev/null 2>&1 || { echo "ERREUR : parted requis"; exit 1; }

	echo "==> Source BOOT : $WORKING_IMG"
	echo "==> Rootfs      : $ROOTFS_TAR"
	telmi_umount_all

	echo "==> Écriture amorce / GPT stock (16 Mo)..."
	dd if="$WORKING_IMG" of="$DEV" bs=512 count="$BOOT_RESERVED_SECTORS" conv=fsync status=progress

	echo "==> GPT : corrige taille disque + p2 root + p3 TELMI (reste)..."
	telmi_need_sgdisk
	sgdisk -e "$DEV" 2>/dev/null || true
	for _p in 5 4 3 2; do
		parted -s "$DEV" rm "$_p" 2>/dev/null || true
	done
	if ! parted -s "$DEV" unit s print 2>/dev/null | grep -q '^ 1 '; then
		parted -s "$DEV" mklabel gpt
		parted -s "$DEV" mkpart primary fat32 "${BOOT_RESERVED_SECTORS}s" "${BOOT_PART_END}s"
	fi
	parted -s "$DEV" mkpart primary ext4 "${ROOT_PART_START}s" "${ROOT_PART_END}s"
	parted -s "$DEV" mkpart primary fat32 "${TELMI_PART_START}s" "${TELMI_PART_END}s"
	parted -s "$DEV" set 1 boot on
	parted -s "$DEV" set 1 esp off 2>/dev/null || true
	sgdisk -t 1:0C00 -A 1:set:2 -c 1:boot -c 2:rootfs -c 3:TELMI "$DEV" 2>/dev/null || true
	wait_parts 3

	echo "==> Copie partition BOOT stock (500 Mo)..."
	dd if="$WORKING_IMG" of="$DEV" bs=512 skip="$BOOT_RESERVED_SECTORS" \
		seek="$BOOT_RESERVED_SECTORS" count="$BOOT_PART_SECTORS" conv=fsync status=progress

	echo "==> Format + extraction rootfs..."
	mkfs.ext4 -F -L rootfs "$(part_path 2)"
	mkdir -p /mnt/telmi-flash-root
	mount "$(part_path 2)" /mnt/telmi-flash-root
	tar -xf "$ROOTFS_TAR" -C /mnt/telmi-flash-root --no-same-owner
	rsync -rl "$TELMI_R36/overlay/" /mnt/telmi-flash-root/
	sync_telmi_bins_from_latest_img /mnt/telmi-flash-root
	find /mnt/telmi-flash-root/etc/init.d -type f -name 'S*' -exec sed -i 's/\r$//' {} +
	sed -i 's/\r$//' /mnt/telmi-flash-root/opt/telmi/bin/telmi-runtime.sh
	find /mnt/telmi-flash-root/etc/init.d /mnt/telmi-flash-root/opt/telmi/bin \
		-type f \( -name '*.sh' -o -name 'S*' \) -exec sed -i 's/\r$//' {} +
	chmod +x /mnt/telmi-flash-root/opt/telmi/bin/* || true
	cp -f "$TELMI_R36/overlay/etc/fstab" /mnt/telmi-flash-root/etc/fstab
	mkdir -p /mnt/telmi-flash-root/opt/telmi/telmiVersion
	echo -n "${VERSION}" > /mnt/telmi-flash-root/opt/telmi/telmiVersion/image-version.txt
	echo "${BUILD_ID}" > /mnt/telmi-flash-root/opt/telmi/telmiVersion/build-id.txt
	sync
	umount /mnt/telmi-flash-root

	write_boot_extlinux "$(part_path 1)"
	echo "==> Format TELMI FAT32 (~${TELMI_SIZE_MB} Mo)..."
	telmi_format_fat32 "$(part_path 3)" TELMI
	seed_telmi_content "$(part_path 3)" 0
}

case "$MODE" in
	from-image)
		flash_from_image
		expand_telmi_partition
		;;
	os-only)
		flash_from_image
		echo " Mode os-only : pas d'expand p3 (contenu via Prepare-Content-SD)"
		;;
	expand)
		telmi_umount_all
		expand_telmi_partition
		;;
	full)
		flash_full
		;;
	*)
		echo "Mode inconnu : $MODE"
		exit 1
		;;
esac

sync
echo ""
echo "============================================================"
if [[ "$MODE" = "os-only" ]]; then
	echo " Flash OS OK (dual-SD) — TelmiOS $VERSION"
	echo " Ensuite : Prepare-Content-SD.sh (slot gauche) + Select-Telmi-REV.sh"
else
	echo " Flash/expand OK — $DEV prêt (TelmiOS $VERSION)"
	echo " Ensuite : Select-Telmi-REV.sh  (V20 / V30 Panel4 / Y3506)"
fi
echo "============================================================"
if [[ "$TELMI_OS" = "macos" ]]; then
	diskutil list "$DEV"
else
	lsblk -o NAME,SIZE,FSTYPE,LABEL "$DEV" 2>/dev/null || lsblk "$DEV"
fi
