#!/usr/bin/env bash
# Image TelmiOS R36S : BOOT stock (500 Mo) + rootfs + partition TELMI (FAT32)
# Boot : meme methode que assemble-v20-light-hello.sh (qui marche)
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TELMI_R36="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$(cd "$TELMI_R36/.." && pwd)"
WORKING_IMG="${1:-}"
if [[ -z "$WORKING_IMG" ]]; then
	for cand in \
		"$TELMI_R36/output/Base.img" \
		"$PROJECT_DIR/R36S-Clone_V20_2025-05-08.img" \
		"$PROJECT_DIR/output/r36s-v20-helloworld-light.img"
	do
		[[ -f "$cand" ]] && WORKING_IMG="$cand" && break
	done
fi
OUTPUT_DIR="$TELMI_R36/output"
VERSION="$(tr -d '[:space:]' < "$TELMI_R36/VERSION" 2>/dev/null || echo "0.0.0")"
# Suffixe optionnel (ex: IMG_SUFFIX=-32g) pour une image variante sans toucher VERSION
IMG_SUFFIX="${IMG_SUFFIX:-}"
BUILD_ID="$(date '+%Y%m%d-%H%M')"
OUTPUT_IMG="$OUTPUT_DIR/telmi-r36-v20-${VERSION}${IMG_SUFFIX}.img"
ROOTFS_TAR="$OUTPUT_DIR/rootfs.tar"
CONTENT_DIR="$TELMI_R36/content"

# Defaut compact : BOOT~516 + root 1536 + TELMI ~100 Mo ≈ 2152 Mo total
# (plus rapide a assembler/flasher). Override : IMG_SIZE_MB=4096 etc.
IMG_SIZE_MB="${IMG_SIZE_MB:-2152}"
ROOT_PART_SIZE_MB="${ROOT_PART_SIZE_MB:-1536}"
BOOT_RESERVED_SECTORS=32768
BOOT_PART_SECTORS=1024000
ROOT_PART_START=1056768

[[ $EUID -eq 0 ]] || { echo "ERREUR : sudo requis"; exit 1; }
[[ -f "$WORKING_IMG" ]] || { echo "ERREUR : $WORKING_IMG"; exit 1; }
[[ -f "$ROOTFS_TAR" ]] || { echo "ERREUR : lancez build-telmi-rootfs.sh"; exit 1; }

mkdir -p "$OUTPUT_DIR" "$CONTENT_DIR/Stories" "$CONTENT_DIR/Music" \
	"$CONTENT_DIR/Games" "$CONTENT_DIR/Saves/Stories" "$CONTENT_DIR/logs"

if [[ -f "$OUTPUT_IMG" ]]; then
	echo "ERREUR : $OUTPUT_IMG existe deja."
	echo "Incrementez Telmi-R36/VERSION avant de reconstruire."
	exit 1
fi

echo "==> Image TelmiOS ${VERSION} (${IMG_SIZE_MB} Mo, BOOT + root ${ROOT_PART_SIZE_MB} Mo + TELMI)"
echo "    Sortie : $OUTPUT_IMG"

truncate -s "${IMG_SIZE_MB}MiB" "$OUTPUT_IMG"
dd if="$WORKING_IMG" of="$OUTPUT_IMG" bs=512 count="$BOOT_RESERVED_SECTORS" conv=notrunc status=none

TOTAL_SECTORS=$(($(stat -c%s "$OUTPUT_IMG") / 512))
ROOT_PART_SECTORS=$((ROOT_PART_SIZE_MB * 1024 * 1024 / 512))
ROOT_PART_END=$((ROOT_PART_START + ROOT_PART_SECTORS - 1))
TELMI_PART_START=$((ROOT_PART_END + 1))
TELMI_PART_END=$((TOTAL_SECTORS - 34))
TELMI_SIZE_MB=$(( (TELMI_PART_END - TELMI_PART_START + 1) * 512 / 1024 / 1024 ))

if [[ $TELMI_PART_END -le $TELMI_PART_START ]]; then
	echo "ERREUR : pas assez d'espace pour TELMI (IMG_SIZE_MB=$IMG_SIZE_MB)"
	exit 1
fi

BOOT_PART_END=$((BOOT_RESERVED_SECTORS + BOOT_PART_SECTORS - 1))
echo "==> GPT : corrige taille + p2 ${ROOT_PART_SIZE_MB} Mo + p3 TELMI ~${TELMI_SIZE_MB} Mo..."
# Corrige la GPT secondaire apres agrandissement de l'image
if command -v sgdisk >/dev/null 2>&1; then
	sgdisk -e "$OUTPUT_IMG" 2>/dev/null || true
fi
# Supprime partitions au-dela de p1 (source peut etre 2 ou 3 parts)
for _p in 5 4 3 2; do
	parted -s "$OUTPUT_IMG" rm "$_p" 2>/dev/null || true
done
# Assure p1
if ! parted -s "$OUTPUT_IMG" unit s print 2>/dev/null | grep -q '^ 1 '; then
	parted -s "$OUTPUT_IMG" mklabel gpt
	parted -s "$OUTPUT_IMG" mkpart primary fat32 "${BOOT_RESERVED_SECTORS}s" "${BOOT_PART_END}s"
fi
parted -s "$OUTPUT_IMG" mkpart primary ext4 "${ROOT_PART_START}s" "${ROOT_PART_END}s"
parted -s "$OUTPUT_IMG" mkpart primary fat32 "${TELMI_PART_START}s" "${TELMI_PART_END}s"
parted -s "$OUTPUT_IMG" set 1 boot on
parted -s "$OUTPUT_IMG" set 1 esp off 2>/dev/null || true
if command -v sgdisk >/dev/null 2>&1; then
	sgdisk -t 1:0C00 -A 1:set:2 -c 1:boot "$OUTPUT_IMG" 2>/dev/null || true
fi

echo "==> Copie partition BOOT stock (500 Mo)..."
dd if="$WORKING_IMG" of="$OUTPUT_IMG" bs=512 skip="$BOOT_RESERVED_SECTORS" \
	count="$BOOT_PART_SECTORS" seek="$BOOT_RESERVED_SECTORS" conv=notrunc status=none

LOOP="$(losetup --show -f -P "$OUTPUT_IMG")"
sleep 1
[[ -b "${LOOP}p1" && -b "${LOOP}p2" && -b "${LOOP}p3" ]] || { echo "ERREUR : partitions introuvables"; exit 1; }
cleanup() {
	umount /mnt/telmi-root /mnt/telmi-boot /mnt/telmi-content 2>/dev/null || true
	losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> Format p2 rootfs + p3 TELMI (FAT32)..."
mkfs.ext4 -F -L rootfs "${LOOP}p2"
mkfs.vfat -F 32 -n TELMI "${LOOP}p3"

mkdir -p /mnt/telmi-root /mnt/telmi-boot /mnt/telmi-content
mount "${LOOP}p2" /mnt/telmi-root
tar -xf "$ROOTFS_TAR" -C /mnt/telmi-root --no-same-owner
rsync -a "$TELMI_R36/overlay/" /mnt/telmi-root/
# Strip CRLF uniquement sur les scripts texte (jamais les binaires ELF)
find /mnt/telmi-root/etc/init.d -type f -name 'S*' -exec sed -i 's/\r$//' {} +
sed -i 's/\r$//' /mnt/telmi-root/opt/telmi/bin/telmi-runtime.sh
find /mnt/telmi-root/etc/init.d -type f -name 'S*' -exec chmod +x {} +
find /mnt/telmi-root/opt/telmi/bin -type f -name '*.sh' -exec chmod +x {} +
chmod +x /mnt/telmi-root/opt/telmi/bin/*
cp -f "$TELMI_R36/overlay/etc/fstab" /mnt/telmi-root/etc/fstab
mkdir -p /mnt/telmi-root/opt/telmi/telmiVersion
echo -n "${VERSION}" > /mnt/telmi-root/opt/telmi/telmiVersion/image-version.txt
echo "${BUILD_ID}" > /mnt/telmi-root/opt/telmi/telmiVersion/build-id.txt
umount /mnt/telmi-root

mount "${LOOP}p3" /mnt/telmi-content
rsync -rl --no-owner --no-group --no-perms --exclude='.gitkeep' --exclude='.git' "$CONTENT_DIR/" /mnt/telmi-content/
if [[ -f "$TELMI_R36/assets/res/miyoo283_system.json" && ! -f /mnt/telmi-content/system.json ]]; then
	cp -f "$TELMI_R36/assets/res/miyoo283_system.json" /mnt/telmi-content/system.json
fi
cat > /mnt/telmi-content/README.txt <<'EOF'
TelmiOS — partition TELMI (FAT32, comme EASYROMS)

Stories/<NomHistorie>/nodes.json, images/, audios/
Music/*.mp3
Saves/
system.json

Montee sur la console a /telmi (= /mnt/SDCARD).
EOF
umount /mnt/telmi-content

mount "${LOOP}p1" /mnt/telmi-boot
mkdir -p /mnt/telmi-boot/extlinux
cat > /mnt/telmi-boot/extlinux/extlinux.conf <<'EOF'
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
cat > /mnt/telmi-boot/TELMI-README.txt <<EOF
TelmiOS R36S — partition BOOT (stock V20)

Version image : ${VERSION}
Build         : ${BUILD_ID}

Contenu Telmi sur partition TELMI (p3, FAT32, label TELMI).
Logs boot : telmi-runtime.log, sdl-steps.log, bootScreen.steps
EOF
echo -n "${VERSION}" > /mnt/telmi-boot/TELMI-VERSION.txt
printf 'TelmiOS %s build %s\n' "$VERSION" "$BUILD_ID" > /mnt/telmi-boot/telmi-runtime.log
umount /mnt/telmi-boot

sync
# Pointeur latest (pas de 2e copie 4 Go)
echo "$(basename "$OUTPUT_IMG")" > "$OUTPUT_DIR/LATEST.txt"
{
	echo "version=${VERSION}"
	echo "build=${BUILD_ID}"
	echo "file=$(basename "$OUTPUT_IMG")"
	echo "size_mb=${IMG_SIZE_MB}"
	echo "source=$(basename "$WORKING_IMG")"
	echo "date=$(date -Iseconds)"
} > "$OUTPUT_DIR/telmi-r36-v20-${VERSION}${IMG_SUFFIX}.manifest.txt"
cp -f "$OUTPUT_DIR/telmi-r36-v20-${VERSION}${IMG_SUFFIX}.manifest.txt" "$OUTPUT_DIR/telmi-r36-v20-latest.manifest.txt"

echo ""
echo "============================================================"
echo " Version : ${VERSION}  (build ${BUILD_ID})"
echo " Image   : $OUTPUT_IMG ($(du -h "$OUTPUT_IMG" | cut -f1))"
echo " Latest  : $(cat "$OUTPUT_DIR/LATEST.txt")"
echo " 3 partitions :"
echo "   p1 BOOT   500 Mo   stock V20 (boot intact)"
echo "   p2 root   ${ROOT_PART_SIZE_MB} Mo   TelmiOS (ext4)"
echo "   p3 TELMI  ~${TELMI_SIZE_MB} Mo   Stories/Music/Saves (FAT32)"
echo " Flashez avec Rufus — slot droite TF-OS"
echo " Prochaine build : incrementez Telmi-R36/VERSION"
echo "============================================================"
