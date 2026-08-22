#!/usr/bin/env bash
# Assemble TelmiOS V30 COMPACT (~taille V20).
#
# Base = image Telmi V20 (noyau 5.10 + rootfs Buildroot), puis :
#   - DTB Panel4 porte (rf3536k3ka-panel4.dtb)
#   - storyTeller profil V30 (ignore zed_keyboard)
#   - annotations BOOT / telmiVersion profil=v30
#
# Pas de root ArkOS 7 Go. Sortie ~2.2 Go.
#
# Usage :
#   bash scripts/assemble-telmi-v30-compact.sh
#   bash scripts/assemble-telmi-v30-compact.sh /chemin/telmi-r36-v20-0.4.39.img
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export MTOOLS_SKIP_CHECK=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TELMI_R36="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS_DIR="$TELMI_R36/.tools"
OUTPUT_DIR="$TELMI_R36/output"
PROFILE_DIR="$TELMI_R36/profiles/v30"
DTB_PORT="$TELMI_R36/dtb_backup/panel-port-5.10/rf3536k3ka-panel4.dtb"
STAGING_V30="$TELMI_R36/staging/v30/opt/telmi/bin"
STAGING_LEGACY="$TELMI_R36/staging/opt/telmi/bin"

VERSION="$(tr -d '[:space:]' < "$PROFILE_DIR/VERSION" 2>/dev/null || echo "0.3.0")"
BUILD_ID="$(date '+%Y%m%d-%H%M')"
OUTPUT_IMG="$OUTPUT_DIR/telmi-r36-v30-${VERSION}.img"

BOOT_RESERVED_SECTORS=32768
BOOT_PART_SECTORS=1024000
ROOT_PART_START=1056768
ROOT_PART_SIZE_MB=1536
ROOT_PART_SECTORS=$((ROOT_PART_SIZE_MB * 1024 * 1024 / 512))

BASE_IMG="${1:-}"
if [[ -z "$BASE_IMG" ]]; then
	if [[ -f "$OUTPUT_DIR/LATEST.txt" ]]; then
		cand="$OUTPUT_DIR/$(tr -d '[:space:]' < "$OUTPUT_DIR/LATEST.txt")"
		[[ -f "$cand" ]] && BASE_IMG="$cand"
	fi
fi
if [[ -z "$BASE_IMG" || ! -f "$BASE_IMG" ]]; then
	BASE_IMG="$(ls -1t "$OUTPUT_DIR"/telmi-r36-v20-*.img 2>/dev/null | head -1 || true)"
fi
[[ -f "$BASE_IMG" ]] || { echo "ERREUR : image V20 de base introuvable"; exit 1; }
[[ -f "$DTB_PORT" ]] || { echo "ERREUR : DTB port Panel4 manquant ($DTB_PORT)"; exit 1; }

STORY=""
for c in "$STAGING_V30/storyTeller" "$OUTPUT_DIR/v30-hotfixes/storyTeller" "$STAGING_LEGACY/storyTeller"; do
	[[ -x "$c" ]] && STORY="$c" && break
done
[[ -n "$STORY" ]] || {
	echo "ERREUR : storyTeller V30 introuvable. Lancez :"
	echo "  bash scripts/build-telmi-bins.sh v30 storyTeller"
	exit 1
}

[[ -x "$TOOLS_DIR/fuse2fs" ]] || { echo "ERREUR : fuse2fs manquant"; exit 1; }
export LD_LIBRARY_PATH="$TOOLS_DIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
FUSE2FS="$TOOLS_DIR/fuse2fs"

if [[ -f "$OUTPUT_IMG" ]]; then
	echo "ERREUR : $OUTPUT_IMG existe. Incrementez profiles/v30/VERSION."
	exit 1
fi

mkdir -p "$OUTPUT_DIR"
echo "============================================================"
echo " TelmiOS V30 COMPACT (base V20 + DTB Panel4 + bins V30)"
echo " Base   : $BASE_IMG"
echo " DTB    : $DTB_PORT"
echo " story  : $STORY"
echo " Sortie : $OUTPUT_IMG"
echo "============================================================"

echo "==> Copie image (reflink si possible)..."
cp -f --reflink=auto "$BASE_IMG" "$OUTPUT_IMG" 2>/dev/null || cp -f "$BASE_IMG" "$OUTPUT_IMG"

WORKDIR="$(mktemp -d /tmp/telmi-v30-compact-XXXXXX)"
cleanup() {
	fusermount -u "$WORKDIR/root" 2>/dev/null || true
	rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "==> Patch BOOT (DTB Panel4 + annotations)..."
BOOT_IMG="$WORKDIR/boot.fat"
dd if="$OUTPUT_IMG" of="$BOOT_IMG" bs=512 skip="$BOOT_RESERVED_SECTORS" \
	count="$BOOT_PART_SECTORS" status=none
# backup original dtb name inside image if present
mcopy -n -i "$BOOT_IMG" ::/rf3536k3ka.dtb "$WORKDIR/rf3536k3ka.dtb.bak" 2>/dev/null || true
mcopy -o -i "$BOOT_IMG" "$DTB_PORT" ::/rf3536k3ka.dtb
# keep a named copy for clarity
mcopy -o -i "$BOOT_IMG" "$DTB_PORT" ::/rf3536k3ka-panel4.dtb

echo -n "${VERSION}" > "$WORKDIR/TELMI-VERSION.txt"
echo "v30-compact-panel4" > "$WORKDIR/TELMI-PROFILE.txt"
printf 'TelmiOS V30 compact (V20 kernel+rootfs, Panel4 DTB, profile v30) build %s\n' "$BUILD_ID" \
	> "$WORKDIR/TELMI-README.txt"
mcopy -o -i "$BOOT_IMG" "$WORKDIR/TELMI-VERSION.txt" ::/TELMI-VERSION.txt
mcopy -o -i "$BOOT_IMG" "$WORKDIR/TELMI-PROFILE.txt" ::/TELMI-PROFILE.txt
mcopy -o -i "$BOOT_IMG" "$WORKDIR/TELMI-README.txt" ::/TELMI-README.txt

dd if="$BOOT_IMG" of="$OUTPUT_IMG" bs=512 seek="$BOOT_RESERVED_SECTORS" conv=notrunc status=none

echo "==> Patch root (storyTeller V30)..."
ROOT_IMG="$WORKDIR/root.ext"
dd if="$OUTPUT_IMG" of="$ROOT_IMG" bs=512 skip="$ROOT_PART_START" \
	count="$ROOT_PART_SECTORS" status=progress
mkdir -p "$WORKDIR/root"
"$FUSE2FS" -o fakeroot,rw "$ROOT_IMG" "$WORKDIR/root"
sleep 1

mkdir -p "$WORKDIR/root/opt/telmi/bin" "$WORKDIR/root/opt/telmi/telmiVersion"
if [[ -d "$STAGING_V30" ]]; then
	cp -f "$STAGING_V30/"* "$WORKDIR/root/opt/telmi/bin/" 2>/dev/null || true
fi
cp -f "$STORY" "$WORKDIR/root/opt/telmi/bin/storyTeller"
# Runtime overlay (ex. Playback Path=HP sur V30)
if [[ -f "$TELMI_R36/overlay/opt/telmi/bin/telmi-runtime.sh" ]]; then
	cp -f "$TELMI_R36/overlay/opt/telmi/bin/telmi-runtime.sh" \
		"$WORKDIR/root/opt/telmi/bin/telmi-runtime.sh"
fi
# Splash Boot/End : binaire PNG + assets (sinon vieux bootScreen = plein violet)
BOOTSCREEN=""
for c in "$STAGING_V30/bootScreen" "$STAGING_LEGACY/bootScreen"; do
	[[ -x "$c" ]] && BOOTSCREEN="$c" && break
done
if [[ -n "$BOOTSCREEN" ]]; then
	cp -f "$BOOTSCREEN" "$WORKDIR/root/opt/telmi/bin/bootScreen"
fi
mkdir -p "$WORKDIR/root/opt/telmi/res"
if [[ -d "$TELMI_R36/assets/res" ]]; then
	rsync -a "$TELMI_R36/assets/res/" "$WORKDIR/root/opt/telmi/res/"
fi
chmod +x "$WORKDIR/root/opt/telmi/bin/"* 2>/dev/null || true
# Pas de wrapper probe / flag dans une image release
rm -f "$WORKDIR/root/opt/telmi/bin/storyTeller.real" 2>/dev/null || true
rm -rf "$WORKDIR/root/opt/telmi/audio-probe" 2>/dev/null || true

echo -n "${VERSION}" > "$WORKDIR/root/opt/telmi/telmiVersion/image-version.txt"
echo "${BUILD_ID}" > "$WORKDIR/root/opt/telmi/telmiVersion/build-id.txt"
echo "v30" > "$WORKDIR/root/opt/telmi/telmiVersion/profile.txt"
echo "compact-panel4" > "$WORKDIR/root/opt/telmi/telmiVersion/v30-variant.txt"

sync
fusermount -u "$WORKDIR/root"
sleep 1

echo "==> Reinjecte root..."
dd if="$ROOT_IMG" of="$OUTPUT_IMG" bs=512 seek="$ROOT_PART_START" conv=notrunc status=progress

sync
echo "$(basename "$OUTPUT_IMG")" > "$OUTPUT_DIR/LATEST-V30.txt"
{
	echo "profile=v30-compact"
	echo "version=${VERSION}"
	echo "variant=panel4-dtb-port"
	echo "build=${BUILD_ID}"
	echo "file=$(basename "$OUTPUT_IMG")"
	echo "base=$(basename "$BASE_IMG")"
	echo "dtb=rf3536k3ka-panel4.dtb"
} > "$OUTPUT_DIR/telmi-r36-v30-${VERSION}.manifest.txt"

# Copie aussi dans hotfixes pour reference
mkdir -p "$OUTPUT_DIR/v30-hotfixes"
cp -f "$DTB_PORT" "$OUTPUT_DIR/v30-hotfixes/rf3536k3ka.dtb"
cp -f "$STORY" "$OUTPUT_DIR/v30-hotfixes/storyTeller"

echo ""
echo "============================================================"
echo " OK $OUTPUT_IMG ($(du -h "$OUTPUT_IMG" | cut -f1))"
echo " Flash : Flash-Telmi-SD-V30.bat"
echo "============================================================"
