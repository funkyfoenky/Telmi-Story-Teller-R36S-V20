#!/usr/bin/env bash
# Assemble TelmiOS profil V30 (rootless) — INDEPENDANT du profil V20.
#
# Layout base sur img_stock/Base_V30.img (MBR, BOOT ~112 Mo) :
#   p1 BOOT  32768s .. 262143s   (229376 secteurs)
#   p2 root  262144s + 1536 Mo
#   p3 TELMI reste
#
# - Sortie  : output/telmi-r36-v30-<VERSION>.img
# - Version : profiles/v30/VERSION
# - Pointeur: output/LATEST-V30.txt  (PAS LATEST.txt)
#
# Usage :
#   bash scripts/assemble-telmi-v30-rootless.sh
#   bash scripts/assemble-telmi-v30-rootless.sh /chemin/Base_V30.img
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export MTOOLS_SKIP_CHECK=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TELMI_R36="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$(cd "$TELMI_R36/.." && pwd)"
TOOLS_DIR="$TELMI_R36/.tools"
PROFILE_DIR="$TELMI_R36/profiles/v30"
# shellcheck source=lib-telmi-v30-boot.sh
source "$SCRIPT_DIR/lib-telmi-v30-boot.sh"

WORKING_IMG="${1:-}"
if [[ -z "$WORKING_IMG" ]]; then
	for cand in \
		"$TELMI_R36/img_stock/Base_V30.img" \
		"$TELMI_R36/output/Base-V30.img" \
		"$PROJECT_DIR/R36S-V30.img"
	do
		[[ -f "$cand" ]] && WORKING_IMG="$cand" && break
	done
fi

OUTPUT_DIR="$TELMI_R36/output"
VERSION="$(tr -d '[:space:]' < "$PROFILE_DIR/VERSION" 2>/dev/null || echo "0.1.0")"
BUILD_ID="$(date '+%Y%m%d-%H%M')"
OUTPUT_IMG="$OUTPUT_DIR/telmi-r36-v30-${VERSION}.img"
ROOTFS_TAR="$OUTPUT_DIR/rootfs.tar"
CONTENT_DIR="$TELMI_R36/content"

IMG_SIZE_MB="${IMG_SIZE_MB:-2152}"
ROOT_PART_SIZE_MB="${ROOT_PART_SIZE_MB:-1536}"
BOOT_RESERVED_SECTORS="$V30_BOOT_RESERVED_SECTORS"
BOOT_PART_SECTORS="$V30_BOOT_PART_SECTORS"
ROOT_PART_START="$V30_ROOT_PART_START"

[[ -f "$WORKING_IMG" ]] || {
	echo "ERREUR : image stock V30 introuvable (img_stock/Base_V30.img)."
	exit 1
}
[[ -f "$ROOTFS_TAR" ]] || { echo "ERREUR : lancez build-telmi-rootfs.sh"; exit 1; }
v30_validate_dtb "$V30_DTB"

ensure_fuse2fs() {
	mkdir -p "$TOOLS_DIR"
	[[ -x "$TOOLS_DIR/fuse2fs" ]] || {
		echo "ERREUR : fuse2fs manquant ($TOOLS_DIR/fuse2fs)"
		exit 1
	}
	export LD_LIBRARY_PATH="$TOOLS_DIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
	FUSE2FS="$TOOLS_DIR/fuse2fs"
}

mkdir -p "$OUTPUT_DIR" "$CONTENT_DIR/Stories" "$CONTENT_DIR/Music" \
	"$CONTENT_DIR/Games" "$CONTENT_DIR/Saves/Stories" "$CONTENT_DIR/logs"

if [[ -f "$OUTPUT_IMG" ]]; then
	echo "ERREUR : $OUTPUT_IMG existe deja. Incrementez profiles/v30/VERSION."
	exit 1
fi

ensure_fuse2fs

echo "============================================================"
echo " TelmiOS profil V30 (MBR) — V20 inchange"
echo " Version : ${VERSION}"
echo " Base    : $WORKING_IMG"
echo " DTB     : $V30_DTB"
echo " BOOT    : ${BOOT_PART_SECTORS} secteurs (~$((BOOT_PART_SECTORS/2048)) Mo)"
echo " Sortie  : $OUTPUT_IMG"
echo "============================================================"

truncate -s "${IMG_SIZE_MB}MiB" "$OUTPUT_IMG"
# Chargeur Rockchip (idbloader+uboot) — memes 16 premiers Mo que le stock
dd if="$WORKING_IMG" of="$OUTPUT_IMG" bs=512 count="$BOOT_RESERVED_SECTORS" conv=notrunc status=none

TOTAL_SECTORS=$(($(stat -c%s "$OUTPUT_IMG") / 512))
ROOT_PART_SECTORS=$((ROOT_PART_SIZE_MB * 1024 * 1024 / 512))
ROOT_PART_END=$((ROOT_PART_START + ROOT_PART_SECTORS - 1))
TELMI_PART_START=$((ROOT_PART_END + 1))
TELMI_PART_END=$((TOTAL_SECTORS - 1))
# MBR : laisser un peu de marge en fin
if [[ $TELMI_PART_END -le $TELMI_PART_START ]]; then
	echo "ERREUR : pas assez d'espace pour TELMI"
	exit 1
fi
TELMI_SIZE_MB=$(( (TELMI_PART_END - TELMI_PART_START + 1) * 512 / 1024 / 1024 ))
BOOT_PART_END=$((BOOT_RESERVED_SECTORS + BOOT_PART_SECTORS - 1))

echo "==> Table MBR (comme stock V30, pas GPT)..."
parted -s "$OUTPUT_IMG" mklabel msdos
parted -s "$OUTPUT_IMG" mkpart primary fat32 "${BOOT_RESERVED_SECTORS}s" "${BOOT_PART_END}s"
parted -s "$OUTPUT_IMG" mkpart primary ext4 "${ROOT_PART_START}s" "${ROOT_PART_END}s"
parted -s "$OUTPUT_IMG" mkpart primary fat32 "${TELMI_PART_START}s" "${TELMI_PART_END}s"
parted -s "$OUTPUT_IMG" set 1 boot on

echo "==> Copie partition BOOT stock V30 (${BOOT_PART_SECTORS} secteurs)..."
dd if="$WORKING_IMG" of="$OUTPUT_IMG" bs=512 skip="$BOOT_RESERVED_SECTORS" \
	count="$BOOT_PART_SECTORS" seek="$BOOT_RESERVED_SECTORS" conv=notrunc status=progress

WORKDIR="$(mktemp -d /tmp/telmi-v30-XXXXXX)"
cleanup() {
	fusermount -u "$WORKDIR/root" 2>/dev/null || true
	rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "==> Rootfs Telmi..."
ROOT_IMG="$WORKDIR/rootfs.ext4"
truncate -s "${ROOT_PART_SIZE_MB}MiB" "$ROOT_IMG"
mkfs.ext4 -F -L rootfs "$ROOT_IMG" >/dev/null
mkdir -p "$WORKDIR/root"
"$FUSE2FS" -o fakeroot,rw "$ROOT_IMG" "$WORKDIR/root"
sleep 1
tar -xf "$ROOTFS_TAR" -C "$WORKDIR/root" --no-same-owner
rsync -rl "$TELMI_R36/overlay/" "$WORKDIR/root/"
find "$WORKDIR/root/etc/init.d" -type f -name 'S*' -exec sed -i 's/\r$//' {} + 2>/dev/null || true
sed -i 's/\r$//' "$WORKDIR/root/opt/telmi/bin/telmi-runtime.sh" 2>/dev/null || true
find "$WORKDIR/root/etc/init.d" "$WORKDIR/root/opt/telmi/bin" -type f \( -name '*.sh' -o -name 'S*' \) | while read -r f; do
	sed -i 's/\r$//' "$f" 2>/dev/null || true
	chmod +x "$f" 2>/dev/null || true
done
chmod +x "$WORKDIR/root/opt/telmi/bin/"* 2>/dev/null || true
cp -f "$TELMI_R36/overlay/etc/fstab" "$WORKDIR/root/etc/fstab"
mkdir -p "$WORKDIR/root/opt/telmi/telmiVersion"
echo -n "${VERSION}" > "$WORKDIR/root/opt/telmi/telmiVersion/image-version.txt"
echo "${BUILD_ID}" > "$WORKDIR/root/opt/telmi/telmiVersion/build-id.txt"
echo "v30" > "$WORKDIR/root/opt/telmi/telmiVersion/profile.txt"
sync
fusermount -u "$WORKDIR/root"
sleep 1

echo "==> Injection rootfs p2..."
dd if="$ROOT_IMG" of="$OUTPUT_IMG" bs=512 seek="$ROOT_PART_START" conv=notrunc status=progress

echo "==> Partition TELMI (~${TELMI_SIZE_MB} Mo)..."
TELMI_IMG="$WORKDIR/telmi.fat"
# mkfs.vfat -C attend une taille en KiB
mkfs.vfat -F 32 -n TELMI -C "$TELMI_IMG" $((TELMI_SIZE_MB * 1024)) >/dev/null
mmd -i "$TELMI_IMG" ::/Stories ::/Music ::/Games ::/Saves ::/Saves/Stories ::/logs
for d in gb gbc gba nes md snes psx; do
	mmd -i "$TELMI_IMG" "::/Games/$d" 2>/dev/null || true
	: > "$WORKDIR/.keep"
	mcopy -o -i "$TELMI_IMG" "$WORKDIR/.keep" "::/Games/$d/.keep" 2>/dev/null || true
done
[[ -f "$CONTENT_DIR/Games/README.txt" ]] && mcopy -o -i "$TELMI_IMG" "$CONTENT_DIR/Games/README.txt" ::/Games/README.txt
[[ -f "$CONTENT_DIR/Saves/README-BIOS-PSX.txt" ]] && mcopy -o -i "$TELMI_IMG" "$CONTENT_DIR/Saves/README-BIOS-PSX.txt" ::/Saves/README-BIOS-PSX.txt
[[ -f "$CONTENT_DIR/README.txt" ]] && mcopy -o -i "$TELMI_IMG" "$CONTENT_DIR/README.txt" ::/README.txt
[[ -f "$CONTENT_DIR/autorun.inf" ]] && mcopy -o -i "$TELMI_IMG" "$CONTENT_DIR/autorun.inf" ::/autorun.inf
[[ -f "$CONTENT_DIR/Saves/.parameters" ]] && mcopy -o -i "$TELMI_IMG" "$CONTENT_DIR/Saves/.parameters" ::/Saves/.parameters
[[ -f "$TELMI_R36/assets/res/miyoo283_system.json" ]] && \
	mcopy -o -i "$TELMI_IMG" "$TELMI_R36/assets/res/miyoo283_system.json" ::/system.json
dd if="$TELMI_IMG" of="$OUTPUT_IMG" bs=512 seek="$TELMI_PART_START" conv=notrunc status=progress

echo "==> Patch BOOT (gameconsole + root mmcblk1p2)..."
BOOT_IMG="$WORKDIR/boot.fat"
dd if="$OUTPUT_IMG" of="$BOOT_IMG" bs=512 skip="$BOOT_RESERVED_SECTORS" \
	count="$BOOT_PART_SECTORS" status=none
v30_patch_boot_fat "$BOOT_IMG" "$VERSION" "$BUILD_ID"
dd if="$BOOT_IMG" of="$OUTPUT_IMG" bs=512 seek="$BOOT_RESERVED_SECTORS" conv=notrunc status=none

sync
echo "$(basename "$OUTPUT_IMG")" > "$OUTPUT_DIR/LATEST-V30.txt"
{
	echo "profile=v30"
	echo "version=${VERSION}"
	echo "build=${BUILD_ID}"
	echo "file=$(basename "$OUTPUT_IMG")"
	echo "dtb=${V30_DTB}"
	echo "layout=msdos"
	echo "boot_sectors=${BOOT_PART_SECTORS}"
	echo "root_start=${ROOT_PART_START}"
	echo "size_mb=${IMG_SIZE_MB}"
	echo "source=$(basename "$WORKING_IMG")"
	echo "date=$(date -Iseconds)"
} > "$OUTPUT_DIR/telmi-r36-v30-${VERSION}.manifest.txt"

echo ""
echo "============================================================"
echo " OK TelmiOS V30 ${VERSION}"
echo " Image  : $OUTPUT_IMG"
echo " LATEST : LATEST-V30.txt"
echo " Flash  : Flash-Telmi-SD-V30.bat  ou Rufus sur ce .img"
echo "============================================================"
