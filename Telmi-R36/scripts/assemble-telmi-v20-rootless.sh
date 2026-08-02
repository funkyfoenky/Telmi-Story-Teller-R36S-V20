#!/usr/bin/env bash
# Assemble TelmiOS V20 SANS sudo (fuse2fs + mtools).
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export MTOOLS_SKIP_CHECK=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TELMI_R36="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$(cd "$TELMI_R36/.." && pwd)"
TOOLS_DIR="$TELMI_R36/.tools"
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
BUILD_ID="$(date '+%Y%m%d-%H%M')"
OUTPUT_IMG="$OUTPUT_DIR/telmi-r36-v20-${VERSION}.img"
ROOTFS_TAR="$OUTPUT_DIR/rootfs.tar"
CONTENT_DIR="$TELMI_R36/content"

IMG_SIZE_MB="${IMG_SIZE_MB:-2152}"
ROOT_PART_SIZE_MB="${ROOT_PART_SIZE_MB:-1536}"
BOOT_RESERVED_SECTORS=32768
BOOT_PART_SECTORS=1024000
ROOT_PART_START=1056768

[[ -f "$WORKING_IMG" ]] || { echo "ERREUR : $WORKING_IMG"; exit 1; }
[[ -f "$ROOTFS_TAR" ]] || { echo "ERREUR : lancez build-telmi-rootfs.sh"; exit 1; }

ensure_fuse2fs() {
	mkdir -p "$TOOLS_DIR"
	if [[ ! -x "$TOOLS_DIR/fuse2fs" ]]; then
		echo "==> Telechargement fuse2fs (rootless)..."
		local tmp
		tmp="$(mktemp -d)"
		(
			cd "$tmp"
			apt-get download fuse2fs libfuse2t64 >/dev/null
			dpkg-deb -x fuse2fs_*.deb fs
			dpkg-deb -x libfuse2t64_*.deb lib
			cp -a fs/usr/bin/fuse2fs "$TOOLS_DIR/fuse2fs"
			mkdir -p "$TOOLS_DIR/lib"
			cp -a lib/lib/x86_64-linux-gnu/libfuse.so* "$TOOLS_DIR/lib/"
		)
		rm -rf "$tmp"
		chmod +x "$TOOLS_DIR/fuse2fs"
	fi
	export LD_LIBRARY_PATH="$TOOLS_DIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
	FUSE2FS="$TOOLS_DIR/fuse2fs"
}

mkdir -p "$OUTPUT_DIR" "$CONTENT_DIR/Stories" "$CONTENT_DIR/Music" \
	"$CONTENT_DIR/Games" "$CONTENT_DIR/Saves/Stories" "$CONTENT_DIR/logs"

if [[ -f "$OUTPUT_IMG" ]]; then
	echo "ERREUR : $OUTPUT_IMG existe deja."
	echo "Incrementez Telmi-R36/VERSION avant de reconstruire."
	exit 1
fi

ensure_fuse2fs

echo "==> Image TelmiOS ${VERSION} (${IMG_SIZE_MB} Mo) [rootless]"
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
	echo "ERREUR : pas assez d'espace pour TELMI"
	exit 1
fi

BOOT_PART_END=$((BOOT_RESERVED_SECTORS + BOOT_PART_SECTORS - 1))
echo "==> GPT..."
if command -v sgdisk >/dev/null 2>&1; then
	sgdisk -e "$OUTPUT_IMG" 2>/dev/null || true
fi
for _p in 5 4 3 2; do
	parted -s "$OUTPUT_IMG" rm "$_p" 2>/dev/null || true
done
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

echo "==> Copie BOOT stock..."
dd if="$WORKING_IMG" of="$OUTPUT_IMG" bs=512 skip="$BOOT_RESERVED_SECTORS" \
	count="$BOOT_PART_SECTORS" seek="$BOOT_RESERVED_SECTORS" conv=notrunc status=none

WORKDIR="$(mktemp -d /tmp/telmi-assemble-XXXXXX)"
cleanup() {
	fusermount -u "$WORKDIR/root" 2>/dev/null || true
	rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "==> Rootfs ext4 (fuse2fs)..."
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
sync
fusermount -u "$WORKDIR/root"
sleep 1

echo "==> Injection rootfs..."
dd if="$ROOT_IMG" of="$OUTPUT_IMG" bs=512 seek="$ROOT_PART_START" conv=notrunc status=progress

echo "==> TELMI FAT 512 Mo..."
TELMI_IMG="$WORKDIR/telmi.fat"
mkfs.vfat -F 32 -n TELMI -C "$TELMI_IMG" $((512 * 1024)) >/dev/null
mmd -i "$TELMI_IMG" ::/Stories ::/Music ::/Games ::/Saves ::/Saves/Stories ::/logs
# Sous-dossiers consoles (visibles sous Windows meme vides)
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

echo "==> Annotations BOOT..."
BOOT_IMG="$WORKDIR/boot.fat"
dd if="$OUTPUT_IMG" of="$BOOT_IMG" bs=512 skip="$BOOT_RESERVED_SECTORS" \
	count="$BOOT_PART_SECTORS" status=none
cat > "$WORKDIR/extlinux.conf" <<'EOF'
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
cat > "$WORKDIR/TELMI-README.txt" <<EOF
TelmiOS R36S ${VERSION} build ${BUILD_ID}
EOF
echo -n "${VERSION}" > "$WORKDIR/TELMI-VERSION.txt"
printf 'TelmiOS %s build %s\n' "$VERSION" "$BUILD_ID" > "$WORKDIR/telmi-runtime.log"
mcopy -o -i "$BOOT_IMG" "$WORKDIR/extlinux.conf" ::/extlinux/extlinux.conf
mcopy -o -i "$BOOT_IMG" "$WORKDIR/TELMI-README.txt" ::/TELMI-README.txt
mcopy -o -i "$BOOT_IMG" "$WORKDIR/TELMI-VERSION.txt" ::/TELMI-VERSION.txt
mcopy -o -i "$BOOT_IMG" "$WORKDIR/telmi-runtime.log" ::/telmi-runtime.log
dd if="$BOOT_IMG" of="$OUTPUT_IMG" bs=512 seek="$BOOT_RESERVED_SECTORS" conv=notrunc status=progress

sync
echo "$(basename "$OUTPUT_IMG")" > "$OUTPUT_DIR/LATEST.txt"
{
	echo "version=${VERSION}"
	echo "build=${BUILD_ID}"
	echo "file=$(basename "$OUTPUT_IMG")"
	echo "size_mb=${IMG_SIZE_MB}"
	echo "date=$(date -Iseconds)"
	echo "method=rootless"
} > "$OUTPUT_DIR/telmi-r36-v20-${VERSION}.manifest.txt"
cp -f "$OUTPUT_DIR/telmi-r36-v20-${VERSION}.manifest.txt" "$OUTPUT_DIR/telmi-r36-v20-latest.manifest.txt"

echo ""
echo "============================================================"
echo " Version : ${VERSION}  (build ${BUILD_ID})"
echo " Image   : $OUTPUT_IMG ($(du -h "$OUTPUT_IMG" | cut -f1))"
echo " Flashez avec Rufus — slot droite TF-OS"
echo "============================================================"
