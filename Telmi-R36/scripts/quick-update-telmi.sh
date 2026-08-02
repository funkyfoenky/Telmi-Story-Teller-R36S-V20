#!/usr/bin/env bash
# Mise a jour rapide TelmiOS : recompile UNIQUEMENT les binaires Telmi
# et les injecte dans une image existante (pas de rebuild Buildroot complet).
#
# Usage :
#   bash Telmi-R36/scripts/quick-update-telmi.sh
#   BASE_IMG=.../telmi-r36-v20-0.4.7.img bash .../quick-update-telmi.sh
#
# Duree typique : 1–3 min (vs 15–20 min assemble complet).
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TELMI_R36="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILDROOT_DIR="${BUILDROOT_DIR:-$HOME/r36s-helloworld-build/buildroot-r36s}"
TOOLS_DIR="$TELMI_R36/.tools"
OUTPUT_DIR="$TELMI_R36/output"
VERSION="$(tr -d '[:space:]' < "$TELMI_R36/VERSION" 2>/dev/null || echo "0.0.0")"
BUILD_ID="$(date '+%Y%m%d-%H%M')"
OUTPUT_IMG="$OUTPUT_DIR/telmi-r36-v20-${VERSION}.img"
JOBS="${JOBS:-$(nproc)}"
export BR2_EXTERNAL="$TELMI_R36/external/telmi-r36"

ROOT_PART_START=1056768
ROOT_PART_SIZE_MB=1536
ROOT_PART_SECTORS=$((ROOT_PART_SIZE_MB * 1024 * 1024 / 512))
BOOT_RESERVED_SECTORS=32768
BOOT_PART_SECTORS=1024000

# Image de base : arg1, BASE_IMG, ou derniere image connue
BASE_IMG="${1:-${BASE_IMG:-}}"
if [[ -z "$BASE_IMG" ]]; then
	if [[ -f "$OUTPUT_DIR/LATEST.txt" ]]; then
		BASE_IMG="$OUTPUT_DIR/$(tr -d '[:space:]' < "$OUTPUT_DIR/LATEST.txt")"
	fi
fi
if [[ -z "$BASE_IMG" || ! -f "$BASE_IMG" ]]; then
	# Fallback : plus recente telmi-r36-v20-*.img
	BASE_IMG="$(ls -1t "$OUTPUT_DIR"/telmi-r36-v20-*.img 2>/dev/null | head -1 || true)"
fi
[[ -f "$BASE_IMG" ]] || { echo "ERREUR : aucune image de base (BASE_IMG=...)"; exit 1; }

if [[ -f "$OUTPUT_IMG" ]]; then
	echo "ERREUR : $OUTPUT_IMG existe deja. Incrementez VERSION."
	exit 1
fi

ensure_fuse2fs() {
	mkdir -p "$TOOLS_DIR"
	if [[ ! -x "$TOOLS_DIR/fuse2fs" ]]; then
		echo "ERREUR : fuse2fs manquant ($TOOLS_DIR/fuse2fs). Lancez d'abord un assemble complet."
		exit 1
	fi
	export LD_LIBRARY_PATH="$TOOLS_DIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
	FUSE2FS="$TOOLS_DIR/fuse2fs"
}

echo "==> Quick update TelmiOS ${VERSION}"
echo "    Base   : $BASE_IMG"
echo "    Sortie : $OUTPUT_IMG"

# Sync overlay Buildroot (runtime scripts)
OVERLAY_DST="$BUILDROOT_DIR/board/telmi-r36/overlay"
mkdir -p "$OVERLAY_DST"
rsync -a "$TELMI_R36/overlay/" "$OVERLAY_DST/"
find "$OVERLAY_DST" -type f \( -name '*.sh' -o -name 'fstab' -o -name 'S*' -o -name 'asound.conf' \) -exec sed -i 's/\r$//' {} + 2>/dev/null || true

echo "==> Compile package telmi-r36s uniquement..."
make -C "$BUILDROOT_DIR" telmi-r36s-dirclean
make -C "$BUILDROOT_DIR" telmi-r36s -j"$JOBS"

STORY="$BUILDROOT_DIR/output/target/opt/telmi/bin/storyTeller"
[[ -x "$STORY" ]] || STORY="$TELMI_R36/staging/opt/telmi/bin/storyTeller"
[[ -x "$STORY" ]] || { echo "ERREUR : storyTeller introuvable apres compile"; exit 1; }

ensure_fuse2fs
WORKDIR="$(mktemp -d /tmp/telmi-quick-XXXXXX)"
cleanup() {
	fusermount -u "$WORKDIR/root" 2>/dev/null || true
	rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "==> Copie image de base..."
cp -f --reflink=auto "$BASE_IMG" "$OUTPUT_IMG" 2>/dev/null || cp -f "$BASE_IMG" "$OUTPUT_IMG"

echo "==> Extraction rootfs p2..."
ROOT_IMG="$WORKDIR/rootfs.ext4"
dd if="$OUTPUT_IMG" of="$ROOT_IMG" bs=512 skip="$ROOT_PART_START" \
	count="$ROOT_PART_SECTORS" status=none

mkdir -p "$WORKDIR/root"
"$FUSE2FS" -o fakeroot,rw "$ROOT_IMG" "$WORKDIR/root"
sleep 1

echo "==> Injection binaires + overlay leger..."
mkdir -p "$WORKDIR/root/opt/telmi/bin" "$WORKDIR/root/opt/telmi/telmiVersion" \
	"$WORKDIR/root/opt/telmi/res" "$WORKDIR/root/opt/telmi/lib/cores"
cp -f "$BUILDROOT_DIR/output/target/opt/telmi/bin/"* "$WORKDIR/root/opt/telmi/bin/" 2>/dev/null || \
	cp -f "$TELMI_R36/staging/opt/telmi/bin/"* "$WORKDIR/root/opt/telmi/bin/"
# Cores libretro
if [ -d "$BUILDROOT_DIR/output/target/opt/telmi/lib/cores" ]; then
	rsync -rl "$BUILDROOT_DIR/output/target/opt/telmi/lib/cores/" "$WORKDIR/root/opt/telmi/lib/cores/"
elif [ -d "$TELMI_R36/staging/opt/telmi/lib/cores" ]; then
	rsync -rl "$TELMI_R36/staging/opt/telmi/lib/cores/" "$WORKDIR/root/opt/telmi/lib/cores/"
fi
# Ressources splash / UI si presentes dans le target Buildroot
if [ -d "$BUILDROOT_DIR/output/target/opt/telmi/res" ]; then
	rsync -rl "$BUILDROOT_DIR/output/target/opt/telmi/res/" "$WORKDIR/root/opt/telmi/res/"
elif [ -d "$TELMI_R36/assets/res" ]; then
	rsync -rl "$TELMI_R36/assets/res/" "$WORKDIR/root/opt/telmi/res/"
fi
# Overlay scripts (runtime, init) si modifies
rsync -a "$TELMI_R36/overlay/opt/telmi/bin/" "$WORKDIR/root/opt/telmi/bin/" 2>/dev/null || true
rsync -a "$TELMI_R36/overlay/etc/" "$WORKDIR/root/etc/" 2>/dev/null || true
# CRLF uniquement sur scripts shell — jamais sur les ELF
find "$WORKDIR/root/opt/telmi/bin" -type f -name '*.sh' -exec sed -i 's/\r$//' {} + 2>/dev/null || true
find "$WORKDIR/root/etc/init.d" -type f -name 'S*telmi*' -exec sed -i 's/\r$//' {} + 2>/dev/null || true
chmod +x "$WORKDIR/root/opt/telmi/bin/"* 2>/dev/null || true
chmod +x "$WORKDIR/root/etc/init.d/"S*telmi* 2>/dev/null || true
chmod +x "$WORKDIR/root/etc/init.d/S98telmi-fb" 2>/dev/null || true
echo -n "${VERSION}" > "$WORKDIR/root/opt/telmi/telmiVersion/image-version.txt"
echo "${BUILD_ID}" > "$WORKDIR/root/opt/telmi/telmiVersion/build-id.txt"
sync
fusermount -u "$WORKDIR/root"
sleep 1

echo "==> Reinjection rootfs..."
dd if="$ROOT_IMG" of="$OUTPUT_IMG" bs=512 seek="$ROOT_PART_START" conv=notrunc status=progress

echo "==> Annotations BOOT (version + rootdelay)..."
BOOT_IMG="$WORKDIR/boot.fat"
dd if="$OUTPUT_IMG" of="$BOOT_IMG" bs=512 skip="$BOOT_RESERVED_SECTORS" \
	count="$BOOT_PART_SECTORS" status=none
echo -n "${VERSION}" > "$WORKDIR/TELMI-VERSION.txt"
printf 'TelmiOS %s build %s (quick-update)\n' "$VERSION" "$BUILD_ID" > "$WORKDIR/TELMI-README.txt"
printf 'TelmiOS %s build %s\n' "$VERSION" "$BUILD_ID" > "$WORKDIR/telmi-runtime.log"
mcopy -o -i "$BOOT_IMG" "$WORKDIR/TELMI-VERSION.txt" ::/TELMI-VERSION.txt
mcopy -o -i "$BOOT_IMG" "$WORKDIR/TELMI-README.txt" ::/TELMI-README.txt
mcopy -o -i "$BOOT_IMG" "$WORKDIR/telmi-runtime.log" ::/telmi-runtime.log
# Accelere le boot kernel : rootdelay=10 → 2
if mcopy -n -i "$BOOT_IMG" ::/extlinux/extlinux.conf "$WORKDIR/extlinux.conf" 2>/dev/null; then
	sed -i 's/rootdelay=10/rootdelay=2/g' "$WORKDIR/extlinux.conf"
	mcopy -o -i "$BOOT_IMG" "$WORKDIR/extlinux.conf" ::/extlinux/extlinux.conf
fi
dd if="$BOOT_IMG" of="$OUTPUT_IMG" bs=512 seek="$BOOT_RESERVED_SECTORS" conv=notrunc status=none

# Assure Games/gba + Games/psx sur la partition TELMI (p3)
echo "==> Sync dossiers Games sur TELMI (p3)..."
bash "$SCRIPT_DIR/inject-games-dirs.sh" "$OUTPUT_IMG" || \
	echo "ATTENTION : inject-games-dirs a echoue (dossiers a creer a la main sur TELMI)"

sync
echo "$(basename "$OUTPUT_IMG")" > "$OUTPUT_DIR/LATEST.txt"
{
	echo "version=${VERSION}"
	echo "build=${BUILD_ID}"
	echo "file=$(basename "$OUTPUT_IMG")"
	echo "date=$(date -Iseconds)"
	echo "method=quick-update"
	echo "base=$(basename "$BASE_IMG")"
} > "$OUTPUT_DIR/telmi-r36-v20-${VERSION}.manifest.txt"

echo ""
echo "============================================================"
echo " Version : ${VERSION}  (build ${BUILD_ID}) [QUICK]"
echo " Image   : ${OUTPUT_IMG}"
echo " Base    : $(basename "$BASE_IMG")"
echo "============================================================"
