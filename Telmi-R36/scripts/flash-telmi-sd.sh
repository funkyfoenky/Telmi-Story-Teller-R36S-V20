#!/usr/bin/env bash
# Flash TelmiOS sur une carte SD reelle : BOOT + root fixes, TELMI = tout le reste.
#
# Usage (WSL, root) :
#   sudo bash scripts/flash-telmi-sd.sh /dev/sdX --from-image
#   sudo bash scripts/flash-telmi-sd.sh /dev/sdX --expand
#   sudo bash scripts/flash-telmi-sd.sh /dev/sdX --yes
#
# Modes :
#   --from-image / --latest
#             Ecrit l'image TelmiOS LATEST (toutes nouveautes), puis agrandit TELMI
#   (defaut)  Formate la SD, ecrit BOOT + rootfs.tar (+ sync bins LATEST), TELMI = reste
#   --expand  Apres Rufus d'une .img compacte : recree seulement p3 TELMI
#             jusqu'a la fin du disque (sans toucher BOOT/root)
#
# Sous WSL2, monter d'abord le lecteur (PowerShell admin) :
#   wsl --mount \\.\PHYSICALDRIVEn --bare
#   Puis lsblk pour trouver /dev/sdX
#
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TELMI_R36="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$(cd "$TELMI_R36/.." && pwd)"
OUTPUT_DIR="$TELMI_R36/output"
CONTENT_DIR="$TELMI_R36/content"
VERSION="$(tr -d '[:space:]' < "$TELMI_R36/VERSION" 2>/dev/null || echo "0.0.0")"
BUILD_ID="$(date '+%Y%m%d-%H%M')"

ROOTFS_TAR="$OUTPUT_DIR/rootfs.tar"
ROOT_PART_SIZE_MB="${ROOT_PART_SIZE_MB:-1536}"
BOOT_RESERVED_SECTORS=32768
BOOT_PART_SECTORS=1024000
ROOT_PART_START=1056768

DEV=""
MODE="full"   # full | expand | from-image
AUTO_YES=0
WORKING_IMG=""

usage() {
	sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
	exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		-h|--help) usage 0 ;;
		--expand) MODE="expand"; shift ;;
		--from-image|--latest) MODE="from-image"; shift ;;
		--yes|-y) AUTO_YES=1; shift ;;
		--image)
			WORKING_IMG="${2:-}"
			[[ -n "$WORKING_IMG" ]] || { echo "ERREUR : --image sans chemin"; exit 1; }
			shift 2
			;;
		/dev/*)
			DEV="$1"
			shift
			;;
		*)
			echo "Argument inconnu : $1"
			usage 1
			;;
	esac
done

[[ $EUID -eq 0 ]] || { echo "ERREUR : root requis (wsl -u root ou sudo)"; exit 1; }

if [[ -z "$DEV" ]]; then
	echo "Disques disponibles :"
	lsblk -o NAME,SIZE,TYPE,TRAN,MODEL,MOUNTPOINTS
	echo ""
	echo "Usage : $0 /dev/sdX [--from-image|--expand] [--yes]"
	exit 1
fi

[[ -b "$DEV" ]] || { echo "ERREUR : $DEV n'est pas un block device"; exit 1; }

# Securite : refuser les disques systeme evidents
DEV_BASE="$(basename "$DEV")"
if [[ "$DEV_BASE" =~ ^(sda|nvme0n1|mmcblk0)$ ]] && [[ "${FORCE_SYSTEM_DISK:-0}" != "1" ]]; then
	echo "ERREUR : $DEV ressemble a un disque systeme."
	echo "         Si c'est bien la SD : FORCE_SYSTEM_DISK=1 $0 $DEV ..."
	exit 1
fi

# Demontage si monte
if lsblk -nro MOUNTPOINTS "$DEV" 2>/dev/null | grep -q '[^[:space:]]'; then
	echo "==> Demontage des partitions de $DEV..."
	for p in $(lsblk -nrpo NAME "$DEV" | tail -n +2); do
		umount "$p" 2>/dev/null || umount -l "$p" 2>/dev/null || true
	done
fi

DISK_BYTES="$(blockdev --getsize64 "$DEV")"
DISK_SECTORS="$(blockdev --getsz "$DEV")"
DISK_GB="$(awk -v b="$DISK_BYTES" 'BEGIN { printf "%.1f", b/1000/1000/1000 }')"
DISK_GIB="$(awk -v b="$DISK_BYTES" 'BEGIN { printf "%.2f", b/1024/1024/1024 }')"

if [[ "$DISK_BYTES" -lt $((3 * 1024 * 1024 * 1024)) ]]; then
	echo "ERREUR : disque trop petit ($DISK_GIB GiB) — minimum ~3 GiB"
	exit 1
fi

ROOT_PART_SECTORS=$((ROOT_PART_SIZE_MB * 1024 * 1024 / 512))
ROOT_PART_END=$((ROOT_PART_START + ROOT_PART_SECTORS - 1))
TELMI_PART_START=$((ROOT_PART_END + 1))
TELMI_PART_END=$((DISK_SECTORS - 34))
BOOT_PART_END=$((BOOT_RESERVED_SECTORS + BOOT_PART_SECTORS - 1))
TELMI_SIZE_MB=$(( (TELMI_PART_END - TELMI_PART_START + 1) * 512 / 1024 / 1024 ))

if [[ $TELMI_PART_END -le $TELMI_PART_START ]]; then
	echo "ERREUR : pas assez d'espace pour TELMI"
	exit 1
fi

echo "============================================================"
echo " TelmiOS flash SD"
echo " Device     : $DEV"
echo " Capacite   : ${DISK_GB} Go (~${DISK_GIB} GiB)"
echo " Mode       : $MODE"
echo " Version    : $VERSION ($BUILD_ID)"
echo " p1 BOOT    : 500 Mo"
echo " p2 root    : ${ROOT_PART_SIZE_MB} Mo"
echo " p3 TELMI   : ~${TELMI_SIZE_MB} Mo  (tout le reste)"
echo "============================================================"

if [[ "$AUTO_YES" != "1" ]]; then
	echo ""
	echo "ATTENTION : donnees sur $DEV seront modifiees (mode $MODE)."
	read -r -p "Tapez le chemin du device pour confirmer ($DEV) : " confirm
	[[ "$confirm" == "$DEV" ]] || { echo "Annule."; exit 1; }
fi

resolve_working_img() {
	if [[ -n "$WORKING_IMG" && -f "$WORKING_IMG" ]]; then
		return 0
	fi
	# Prefer image matching VERSION, then LATEST.txt, then newest .img
	if [[ -f "$OUTPUT_DIR/telmi-r36-v20-${VERSION}.img" ]]; then
		WORKING_IMG="$OUTPUT_DIR/telmi-r36-v20-${VERSION}.img"
		return 0
	fi
	if [[ -f "$OUTPUT_DIR/LATEST.txt" ]]; then
		local latest_name
		latest_name="$(tr -d '[:space:]' < "$OUTPUT_DIR/LATEST.txt")"
		if [[ -n "$latest_name" && -f "$OUTPUT_DIR/$latest_name" ]]; then
			WORKING_IMG="$OUTPUT_DIR/$latest_name"
			return 0
		fi
	fi
	local latest
	latest="$(ls -1t "$OUTPUT_DIR"/telmi-r36-v20-*.img 2>/dev/null | head -1 || true)"
	if [[ -n "$latest" && -f "$latest" ]]; then
		WORKING_IMG="$latest"
		return 0
	fi
	# Fallback BOOT-only sources (mode full)
	for cand in \
		"$OUTPUT_DIR/Base.img" \
		"$PROJECT_DIR/R36S-Clone_V20_2025-05-08.img" \
		"$PROJECT_DIR/output/r36s-v20-helloworld-light.img"
	do
		if [[ -f "$cand" ]]; then
			WORKING_IMG="$cand"
			return 0
		fi
	done
	return 1
}

resolve_latest_telmi_img() {
	# Strict : image TelmiOS seulement (pas Base.img)
	if [[ -f "$OUTPUT_DIR/telmi-r36-v20-${VERSION}.img" ]]; then
		echo "$OUTPUT_DIR/telmi-r36-v20-${VERSION}.img"
		return 0
	fi
	if [[ -f "$OUTPUT_DIR/LATEST.txt" ]]; then
		local n
		n="$(tr -d '[:space:]' < "$OUTPUT_DIR/LATEST.txt")"
		if [[ -n "$n" && -f "$OUTPUT_DIR/$n" ]]; then
			echo "$OUTPUT_DIR/$n"
			return 0
		fi
	fi
	local latest
	latest="$(ls -1t "$OUTPUT_DIR"/telmi-r36-v20-*.img 2>/dev/null | head -1 || true)"
	[[ -n "$latest" && -f "$latest" ]] || return 1
	echo "$latest"
}

# Apres rootfs.tar : injecte opt/telmi depuis l'image LATEST (binaires + cores a jour)
sync_telmi_bins_from_latest_img() {
	local root_mnt="$1"
	local img=""
	local tmp root_img mnt
	local tools_dir="$TELMI_R36/.tools"
	local fuse2fs=""
	local skip count

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

	# Taille reelle de p2 dans l'image (peut differer du layout SD)
	skip="$ROOT_PART_START"
	count="$ROOT_PART_SECTORS"
	if command -v parted >/dev/null 2>&1; then
		local p2_start p2_end
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

flash_from_latest_image() {
	local img
	img="$(resolve_latest_telmi_img)" || {
		echo "ERREUR : aucune image telmi-r36-v20-*.img dans $OUTPUT_DIR"
		echo "         Lancez assemble / quick-update d'abord."
		exit 1
	}
	WORKING_IMG="$img"
	local img_bytes img_sectors
	img_bytes="$(stat -c%s "$WORKING_IMG")"
	img_sectors=$((img_bytes / 512))
	if [[ "$DISK_SECTORS" -lt "$img_sectors" ]]; then
		echo "ERREUR : SD trop petite pour $(basename "$WORKING_IMG")"
		exit 1
	fi

	echo "==> Source image TelmiOS : $WORKING_IMG"
	echo "==> Ecriture image complete sur $DEV..."
	dd if="$WORKING_IMG" of="$DEV" bs=4M conv=fsync status=progress
	sync
	# Recree TELMI sur tout l'espace restant + contenu Games a jour
	expand_telmi_partition
	write_boot_extlinux "$(part_path 1)"
}

seed_telmi_content() {
	local part="$1"
	local d
	mkdir -p /mnt/telmi-flash-content
	mount "$part" /mnt/telmi-flash-content
	mkdir -p "$CONTENT_DIR/Stories" "$CONTENT_DIR/Music" \
		"$CONTENT_DIR/Games" "$CONTENT_DIR/Saves/Stories" "$CONTENT_DIR/logs" \
		"$CONTENT_DIR/Games/gb" "$CONTENT_DIR/Games/gbc" "$CONTENT_DIR/Games/gba" \
		"$CONTENT_DIR/Games/nes" "$CONTENT_DIR/Games/md" "$CONTENT_DIR/Games/snes" \
		"$CONTENT_DIR/Games/psx" "$CONTENT_DIR/Saves" "$CONTENT_DIR/config"
	# Sentinelles : dossiers FAT vides invisibles sous Windows sinon
	for d in gb gbc gba nes md snes psx; do
		touch "$CONTENT_DIR/Games/$d/.keep"
	done
	rsync -rl --no-owner --no-group --no-perms --exclude='.gitkeep' --exclude='.git' --exclude='.keep' \
		"$CONTENT_DIR/" /mnt/telmi-flash-content/
	for d in gb gbc gba nes md snes psx; do
		mkdir -p "/mnt/telmi-flash-content/Games/$d"
		touch "/mnt/telmi-flash-content/Games/$d/.keep"
	done
	if [[ -f "$TELMI_R36/assets/res/miyoo283_system.json" && ! -f /mnt/telmi-flash-content/system.json ]]; then
		cp -f "$TELMI_R36/assets/res/miyoo283_system.json" /mnt/telmi-flash-content/system.json
	fi
	cat > /mnt/telmi-flash-content/README.txt <<'EOF'
TelmiOS — partition TELMI (FAT32)

Stories/<NomHistoire>/
Music/*.mp3
Games/
  gb/ gbc/ gba/ nes/ md/ snes/ psx/
Saves/          (BIOS PSX : scph5501.bin etc.)
system.json

Montee sur la console a /telmi (= /mnt/SDCARD).
Select x3 sur le carrousel = mode jeux.
EOF
	if [[ -f "$CONTENT_DIR/Games/README.txt" ]]; then
		mkdir -p /mnt/telmi-flash-content/Games
		cp -f "$CONTENT_DIR/Games/README.txt" /mnt/telmi-flash-content/Games/README.txt
	fi
	sync
	umount /mnt/telmi-flash-content
}

write_boot_extlinux() {
	local part="$1"
	mkdir -p /mnt/telmi-flash-boot
	mount "$part" /mnt/telmi-flash-boot
	mkdir -p /mnt/telmi-flash-boot/extlinux
	cat > /mnt/telmi-flash-boot/extlinux/extlinux.conf <<'EOF'
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
	echo -n "${VERSION}" > /mnt/telmi-flash-boot/TELMI-VERSION.txt
	cat > /mnt/telmi-flash-boot/TELMI-README.txt <<EOF
TelmiOS R36S — partition BOOT (stock V20)
Version : ${VERSION}
Build   : ${BUILD_ID}
Flash   : flash-telmi-sd.sh (${MODE})
EOF
	sync
	umount /mnt/telmi-flash-boot
}

part_path() {
	local n="$1"
	if [[ "$DEV" =~ [0-9]$ ]]; then
		echo "${DEV}p${n}"
	else
		echo "${DEV}${n}"
	fi
}

wait_parts() {
	partprobe "$DEV" 2>/dev/null || true
	sleep 1
	local i
	for i in 1 2 3 4 5 6 7 8 9 10; do
		[[ -b "$(part_path 1)" && -b "$(part_path 2)" && -b "$(part_path 3)" ]] && return 0
		sleep 0.5
		partprobe "$DEV" 2>/dev/null || true
	done
	echo "ERREUR : partitions introuvables apres partitionnement"
	lsblk "$DEV"
	exit 1
}

expand_telmi_partition() {
	echo "==> Correction GPT secondaire + recreation p3 TELMI..."
	if command -v sgdisk >/dev/null 2>&1; then
		sgdisk -e "$DEV" 2>/dev/null || true
	fi
	local p2_end
	p2_end="$(parted -s "$DEV" unit s print 2>/dev/null | awk '/^ 2 / { gsub(/s/,"",$3); print $3; exit }')"
	if [[ -n "${p2_end:-}" ]]; then
		ROOT_PART_END="$p2_end"
		TELMI_PART_START=$((ROOT_PART_END + 1))
		TELMI_SIZE_MB=$(( (TELMI_PART_END - TELMI_PART_START + 1) * 512 / 1024 / 1024 ))
	fi
	parted -s "$DEV" rm 3 2>/dev/null || true
	for _p in 5 4; do
		parted -s "$DEV" rm "$_p" 2>/dev/null || true
	done
	parted -s "$DEV" mkpart primary fat32 "${TELMI_PART_START}s" "${TELMI_PART_END}s"
	if command -v sgdisk >/dev/null 2>&1; then
		sgdisk -c 3:TELMI "$DEV" 2>/dev/null || true
	fi
	wait_parts
	echo "==> Format TELMI FAT32 (~${TELMI_SIZE_MB} Mo)..."
	mkfs.vfat -F 32 -n TELMI "$(part_path 3)"
	seed_telmi_content "$(part_path 3)"
}

flash_full() {
	resolve_working_img || { echo "ERREUR : pas d'image BOOT (Base.img / clone V20)"; exit 1; }
	[[ -f "$ROOTFS_TAR" ]] || { echo "ERREUR : $ROOTFS_TAR manquant — lancez build-telmi-rootfs.sh"; exit 1; }

	echo "==> Source BOOT : $WORKING_IMG"
	echo "==> Rootfs      : $ROOTFS_TAR"

	# Meme ordre que assemble-telmi-v20.sh : amorce stock d'abord, puis GPT adaptee
	echo "==> Ecriture amorce / GPT stock (16 Mo)..."
	dd if="$WORKING_IMG" of="$DEV" bs=512 count="$BOOT_RESERVED_SECTORS" conv=fsync status=progress

	echo "==> GPT : corrige taille disque + p2 root + p3 TELMI (reste)..."
	if command -v sgdisk >/dev/null 2>&1; then
		sgdisk -e "$DEV" 2>/dev/null || true
	fi
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
	if command -v sgdisk >/dev/null 2>&1; then
		sgdisk -t 1:0C00 -A 1:set:2 -c 1:boot -c 2:rootfs -c 3:TELMI "$DEV" 2>/dev/null || true
	fi
	wait_parts

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
	mkfs.vfat -F 32 -n TELMI "$(part_path 3)"
	seed_telmi_content "$(part_path 3)"
}

case "$MODE" in
	expand) expand_telmi_partition ;;
	from-image) flash_from_latest_image ;;
	full) flash_full ;;
	*) echo "Mode inconnu"; exit 1 ;;
esac

sync
echo ""
echo "============================================================"
echo " OK — $DEV pret  (TelmiOS $VERSION)"
echo " p1 BOOT  500 Mo"
echo " p2 root  ${ROOT_PART_SIZE_MB} Mo"
echo " p3 TELMI ~${TELMI_SIZE_MB} Mo (espace restant utilise)"
echo ""
echo " Contenu TELMI : Stories / Music / Games"
echo "   Games/gb gbc gba nes md snes psx"
echo "   Saves/   (BIOS PSX si besoin)"
echo " Branchez la SD (slot droite TF-OS) et demarrez."
echo "============================================================"
lsblk -o NAME,SIZE,FSTYPE,LABEL "$DEV"
