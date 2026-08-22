#!/usr/bin/env bash
# Quick-update profil V30 uniquement.
# - Lit profiles/v30/VERSION
# - Ecrit telmi-r36-v30-*.img + LATEST-V30.txt
# - Ne touche PAS LATEST.txt / telmi-r36-v20-*.img
#
# Usage :
#   bash scripts/quick-update-telmi-v30.sh
#   bash scripts/quick-update-telmi-v30.sh output/telmi-r36-v30-0.1.0.img
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export MTOOLS_SKIP_CHECK=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TELMI_R36="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILDROOT_DIR="${BUILDROOT_DIR:-$HOME/r36s-helloworld-build/buildroot-r36s}"
TOOLS_DIR="$TELMI_R36/.tools"
OUTPUT_DIR="$TELMI_R36/output"
PROFILE_DIR="$TELMI_R36/profiles/v30"
VERSION="$(tr -d '[:space:]' < "$PROFILE_DIR/VERSION" 2>/dev/null || echo "0.1.0")"
BUILD_ID="$(date '+%Y%m%d-%H%M')"
OUTPUT_IMG="$OUTPUT_DIR/telmi-r36-v30-${VERSION}.img"
JOBS="${JOBS:-$(nproc)}"
export BR2_EXTERNAL="$TELMI_R36/external/telmi-r36"

# shellcheck source=lib-telmi-v30-boot.sh
source "$SCRIPT_DIR/lib-telmi-v30-boot.sh"

ROOT_PART_START="$V30_ROOT_PART_START"
ROOT_PART_SIZE_MB=1536
ROOT_PART_SECTORS=$((ROOT_PART_SIZE_MB * 1024 * 1024 / 512))
BOOT_RESERVED_SECTORS="$V30_BOOT_RESERVED_SECTORS"
BOOT_PART_SECTORS="$V30_BOOT_PART_SECTORS"

BASE_IMG="${1:-${BASE_IMG:-}}"
if [[ -z "$BASE_IMG" ]]; then
	if [[ -f "$OUTPUT_DIR/LATEST-V30.txt" ]]; then
		BASE_IMG="$OUTPUT_DIR/$(tr -d '[:space:]' < "$OUTPUT_DIR/LATEST-V30.txt")"
	fi
fi
if [[ -z "$BASE_IMG" || ! -f "$BASE_IMG" ]]; then
	BASE_IMG="$(ls -1t "$OUTPUT_DIR"/telmi-r36-v30-*.img 2>/dev/null | head -1 || true)"
fi
[[ -f "$BASE_IMG" ]] || {
	echo "ERREUR : aucune image V30 de base."
	echo "Assemblez d'abord : bash scripts/assemble-telmi-v30-rootless.sh <stock-V30.img>"
	exit 1
}

if [[ -f "$OUTPUT_IMG" ]]; then
	echo "ERREUR : $OUTPUT_IMG existe deja. Incrementez profiles/v30/VERSION."
	exit 1
fi

ensure_fuse2fs() {
	mkdir -p "$TOOLS_DIR"
	[[ -x "$TOOLS_DIR/fuse2fs" ]] || { echo "ERREUR : fuse2fs manquant"; exit 1; }
	export LD_LIBRARY_PATH="$TOOLS_DIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
	FUSE2FS="$TOOLS_DIR/fuse2fs"
}

echo "==> Quick update TelmiOS V30 ${VERSION}"
echo "    Base   : $BASE_IMG"
echo "    Sortie : $OUTPUT_IMG"
echo "    DTB    : $V30_DTB"

OVERLAY_DST="$BUILDROOT_DIR/board/telmi-r36/overlay"
mkdir -p "$OVERLAY_DST"
rsync -a "$TELMI_R36/overlay/" "$OVERLAY_DST/"
find "$OVERLAY_DST" -type f \( -name '*.sh' -o -name 'fstab' -o -name 'S*' -o -name 'asound.conf' \) -exec sed -i 's/\r$//' {} + 2>/dev/null || true

echo "==> Compile package telmi-r36s (profil v30)..."
make -C "$BUILDROOT_DIR" TELMI_PROFILE=v30 telmi-r36s-dirclean
make -C "$BUILDROOT_DIR" TELMI_PROFILE=v30 telmi-r36s -j"$JOBS"

STORY="$BUILDROOT_DIR/output/target/opt/telmi/bin/storyTeller"
[[ -x "$STORY" ]] || STORY="$TELMI_R36/staging/v30/opt/telmi/bin/storyTeller"
[[ -x "$STORY" ]] || STORY="$TELMI_R36/staging/opt/telmi/bin/storyTeller"
[[ -x "$STORY" ]] || { echo "ERREUR : storyTeller introuvable"; exit 1; }

ensure_fuse2fs
WORKDIR="$(mktemp -d /tmp/telmi-v30-quick-XXXXXX)"
cleanup() {
	fusermount -u "$WORKDIR/root" 2>/dev/null || true
	rm -rf "$WORKDIR"
}
trap cleanup EXIT

cp -f --reflink=auto "$BASE_IMG" "$OUTPUT_IMG" 2>/dev/null || cp -f "$BASE_IMG" "$OUTPUT_IMG"

ROOT_IMG="$WORKDIR/rootfs.ext4"
dd if="$OUTPUT_IMG" of="$ROOT_IMG" bs=512 skip="$ROOT_PART_START" \
	count="$ROOT_PART_SECTORS" status=none
mkdir -p "$WORKDIR/root"
"$FUSE2FS" -o fakeroot,rw "$ROOT_IMG" "$WORKDIR/root"
sleep 1

mkdir -p "$WORKDIR/root/opt/telmi/bin" "$WORKDIR/root/opt/telmi/telmiVersion"
if [[ -d "$BUILDROOT_DIR/output/target/opt/telmi/bin" ]]; then
	cp -f "$BUILDROOT_DIR/output/target/opt/telmi/bin/"* "$WORKDIR/root/opt/telmi/bin/" 2>/dev/null || true
fi
cp -f "$TELMI_R36/staging/v30/opt/telmi/bin/"* "$WORKDIR/root/opt/telmi/bin/" 2>/dev/null || \
	cp -f "$TELMI_R36/staging/opt/telmi/bin/"* "$WORKDIR/root/opt/telmi/bin/" 2>/dev/null || true
chmod +x "$WORKDIR/root/opt/telmi/bin/"* 2>/dev/null || true
echo -n "${VERSION}" > "$WORKDIR/root/opt/telmi/telmiVersion/image-version.txt"
echo "${BUILD_ID}" > "$WORKDIR/root/opt/telmi/telmiVersion/build-id.txt"
echo "v30" > "$WORKDIR/root/opt/telmi/telmiVersion/profile.txt"
sync
fusermount -u "$WORKDIR/root"
sleep 1
dd if="$ROOT_IMG" of="$OUTPUT_IMG" bs=512 seek="$ROOT_PART_START" conv=notrunc status=progress

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
} > "$OUTPUT_DIR/telmi-r36-v30-${VERSION}.manifest.txt"

echo "OK $OUTPUT_IMG (LATEST-V30.txt mis a jour, LATEST.txt V20 inchange)"
