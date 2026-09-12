#!/usr/bin/env bash
# Assemble TelmiOS IMAGE UNIQUE multi-REV (~2.2 Go).
#
# Base = image Telmi V20 (noyau 5.10 + rootfs), puis :
#   - bins unifies (runtime /boot/TELMI-REV.txt)
#   - tous les DTB sous BOOT/dtb/ + DTB actif = v20 par defaut
#   - revs.json + TELMI-REV.txt
#   - bootScreen PNG + assets/res + telmi-runtime.sh
#
# Usage :
#   bash scripts/assemble-telmi-unified.sh
#   bash scripts/assemble-telmi-unified.sh /chemin/telmi-r36-v20-0.4.39.img
#
# Sortie : output/telmi-r36-<VERSION>.img + LATEST.txt
# Post-flash Windows : Select-Telmi-REV.bat
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export MTOOLS_SKIP_CHECK=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TELMI_R36="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS_DIR="$TELMI_R36/.tools"
OUTPUT_DIR="$TELMI_R36/output"
REVS_JSON="$TELMI_R36/boot/revs.json"
DTB_DIR="$TELMI_R36/boot/dtb"
DEFAULT_REV="v20"

VERSION="$(tr -d '[:space:]' < "$TELMI_R36/VERSION" 2>/dev/null || echo "0.5.0")"
BUILD_ID="$(date '+%Y%m%d-%H%M')"
OUTPUT_IMG="$OUTPUT_DIR/telmi-r36-${VERSION}.img"

BOOT_RESERVED_SECTORS=32768
BOOT_PART_SECTORS=1024000
ROOT_PART_START=1056768
ROOT_PART_SIZE_MB=1536
ROOT_PART_SECTORS=$((ROOT_PART_SIZE_MB * 1024 * 1024 / 512))

BASE_IMG="${1:-}"
if [[ -z "$BASE_IMG" ]]; then
	if [[ -f "$OUTPUT_DIR/LATEST.txt" ]]; then
		cand="$OUTPUT_DIR/$(tr -d '[:space:]' < "$OUTPUT_DIR/LATEST.txt")"
		# Prefer a known-good V20 base if LATEST already points to unified
		if [[ -f "$cand" && "$cand" == *v20* ]]; then
			BASE_IMG="$cand"
		fi
	fi
fi
if [[ -z "$BASE_IMG" || ! -f "$BASE_IMG" ]]; then
	BASE_IMG="$(ls -1t "$OUTPUT_DIR"/telmi-r36-v20-*.img 2>/dev/null | head -1 || true)"
fi
[[ -f "$BASE_IMG" ]] || { echo "ERREUR : image V20 de base introuvable"; exit 1; }
[[ -f "$REVS_JSON" ]] || { echo "ERREUR : $REVS_JSON manquant"; exit 1; }
[[ -f "$DTB_DIR/v20.dtb" ]] || { echo "ERREUR : $DTB_DIR/v20.dtb manquant"; exit 1; }
REVS_LIST="$(python3 -c 'import json,sys; print(",".join(r["id"] for r in json.load(open(sys.argv[1]))["revs"]))' "$REVS_JSON")"
while IFS= read -r _rel; do
	_f="$TELMI_R36/boot/${_rel}"
	[[ -f "$_f" ]] || { echo "ERREUR : DTB catalogue manquant : $_f"; exit 1; }
done < <(python3 -c 'import json,sys; [print(r["dtb"]) for r in json.load(open(sys.argv[1]))["revs"]]' "$REVS_JSON")

STAGING_U="$TELMI_R36/staging/unified/opt/telmi/bin"
STAGING_LEGACY="$TELMI_R36/staging/opt/telmi/bin"

pick_bin() {
	local name="$1"
	local c
	for c in "$STAGING_U/$name" "$STAGING_LEGACY/$name"; do
		[[ -x "$c" ]] && { echo "$c"; return 0; }
	done
	return 1
}

STORY="$(pick_bin storyTeller)" || {
	echo "ERREUR : storyTeller unifie introuvable. Lancez :"
	echo "  bash scripts/build-telmi-bins.sh unified storyTeller bootScreen"
	exit 1
}
BOOTSCREEN="$(pick_bin bootScreen || true)"

[[ -x "$TOOLS_DIR/fuse2fs" ]] || { echo "ERREUR : fuse2fs manquant"; exit 1; }
export LD_LIBRARY_PATH="$TOOLS_DIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
FUSE2FS="$TOOLS_DIR/fuse2fs"

if [[ -f "$OUTPUT_IMG" ]]; then
	echo "ERREUR : $OUTPUT_IMG existe. Incrementez VERSION."
	exit 1
fi

mkdir -p "$OUTPUT_DIR"
echo "============================================================"
echo " TelmiOS IMAGE UNIQUE multi-REV"
echo " Base   : $BASE_IMG"
echo " REV def: $DEFAULT_REV"
echo " story  : $STORY"
echo " Sortie : $OUTPUT_IMG"
echo "============================================================"

echo "==> Copie image..."
cp -f --reflink=auto "$BASE_IMG" "$OUTPUT_IMG" 2>/dev/null || cp -f "$BASE_IMG" "$OUTPUT_IMG"

TELMI_OS_ONLY="${TELMI_OS_ONLY:-0}"
if [[ "$TELMI_OS_ONLY" == "1" ]]; then
	echo "==> OS-only dual-SD : suppression partition p3..."
	for _tool in parted sgdisk; do command -v "$_tool" >/dev/null && break; done
	parted -s "$OUTPUT_IMG" rm 3 2>/dev/null || true
	if command -v sgdisk >/dev/null 2>&1; then
		sgdisk -d 3 "$OUTPUT_IMG" 2>/dev/null || true
		sgdisk -e "$OUTPUT_IMG" 2>/dev/null || true
	fi
fi

WORKDIR="$(mktemp -d /tmp/telmi-unified-XXXXXX)"
cleanup() {
	fusermount -u "$WORKDIR/root" 2>/dev/null || true
	rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "==> Patch BOOT (DTBs multi-REV + annotations)..."
BOOT_IMG="$WORKDIR/boot.fat"
dd if="$OUTPUT_IMG" of="$BOOT_IMG" bs=512 skip="$BOOT_RESERVED_SECTORS" \
	count="$BOOT_PART_SECTORS" status=none

# Catalogue + DTB pack (::/dtb deja present sur images unified depuis 0.5.0)
if ! mdir -i "$BOOT_IMG" ::/dtb >/dev/null 2>&1; then
	mmd -i "$BOOT_IMG" ::/dtb
fi
mcopy -o -i "$BOOT_IMG" "$REVS_JSON" ::/revs.json
# Tous les DTB du catalogue (v20 stock, v30-panel4, y3506-v05, …)
while IFS= read -r _rel; do
	_src="$TELMI_R36/boot/${_rel}"
	_base="$(basename "$_rel")"
	mcopy -o -i "$BOOT_IMG" "$_src" "::/dtb/${_base}"
done < <(python3 -c 'import json,sys; [print(r["dtb"]) for r in json.load(open(sys.argv[1]))["revs"]]' "$REVS_JSON")
# Actif = V20 par defaut (stock 107328 o — DTB Telmi 108028 o cassait le boot V20)
mcopy -o -i "$BOOT_IMG" "$DTB_DIR/v20.dtb" ::/rf3536k3ka.dtb

echo -n "$DEFAULT_REV" > "$WORKDIR/TELMI-REV.txt"
echo -n "$DEFAULT_REV" > "$WORKDIR/TELMI-PROFILE.txt"
echo -n "${VERSION}" > "$WORKDIR/TELMI-VERSION.txt"
printf 'TelmiOS unified multi-REV build %s (default %s). Run Select-Telmi-REV.bat after flash.\n' \
	"$BUILD_ID" "$DEFAULT_REV" > "$WORKDIR/TELMI-README.txt"
# Audio path par defaut V20
echo -n "SPK" > "$WORKDIR/TELMI-AUDIO-PATH.txt"

mcopy -o -i "$BOOT_IMG" "$WORKDIR/TELMI-REV.txt" ::/TELMI-REV.txt
mcopy -o -i "$BOOT_IMG" "$WORKDIR/TELMI-PROFILE.txt" ::/TELMI-PROFILE.txt
mcopy -o -i "$BOOT_IMG" "$WORKDIR/TELMI-VERSION.txt" ::/TELMI-VERSION.txt
mcopy -o -i "$BOOT_IMG" "$WORKDIR/TELMI-README.txt" ::/TELMI-README.txt
mcopy -o -i "$BOOT_IMG" "$WORKDIR/TELMI-AUDIO-PATH.txt" ::/TELMI-AUDIO-PATH.txt

dd if="$BOOT_IMG" of="$OUTPUT_IMG" bs=512 seek="$BOOT_RESERVED_SECTORS" conv=notrunc status=none

echo "==> Patch root (bins unifies + res + runtime)..."
ROOT_IMG="$WORKDIR/root.ext"
dd if="$OUTPUT_IMG" of="$ROOT_IMG" bs=512 skip="$ROOT_PART_START" \
	count="$ROOT_PART_SECTORS" status=progress
mkdir -p "$WORKDIR/root"
"$FUSE2FS" -o fakeroot,rw "$ROOT_IMG" "$WORKDIR/root"
sleep 1

mkdir -p "$WORKDIR/root/opt/telmi/bin" "$WORKDIR/root/opt/telmi/telmiVersion" \
	"$WORKDIR/root/opt/telmi/res"
# Tous les bins staging unified disponibles
if [[ -d "$STAGING_U" ]]; then
	cp -f "$STAGING_U/"* "$WORKDIR/root/opt/telmi/bin/" 2>/dev/null || true
fi
cp -f "$STORY" "$WORKDIR/root/opt/telmi/bin/storyTeller"
if [[ -n "${BOOTSCREEN:-}" && -x "$BOOTSCREEN" ]]; then
	cp -f "$BOOTSCREEN" "$WORKDIR/root/opt/telmi/bin/bootScreen"
fi
# Overlay runtime (mount contenu dual-SD, init, fstab sans LABEL=TELMI)
if [[ -d "$TELMI_R36/overlay/opt/telmi/bin" ]]; then
	rsync -a "$TELMI_R36/overlay/opt/telmi/bin/" "$WORKDIR/root/opt/telmi/bin/" 2>/dev/null || true
fi
if [[ -d "$TELMI_R36/overlay/etc" ]]; then
	rsync -a "$TELMI_R36/overlay/etc/" "$WORKDIR/root/etc/" 2>/dev/null || true
fi
find "$WORKDIR/root/opt/telmi/bin" -type f -name '*.sh' -exec sed -i 's/\r$//' {} + 2>/dev/null || true
find "$WORKDIR/root/etc/init.d" -type f -name 'S*telmi*' -exec sed -i 's/\r$//' {} + 2>/dev/null || true
chmod +x "$WORKDIR/root/etc/init.d/"S*telmi* 2>/dev/null || true
if [[ -d "$TELMI_R36/assets/res" ]]; then
	rsync -a "$TELMI_R36/assets/res/" "$WORKDIR/root/opt/telmi/res/"
fi
chmod +x "$WORKDIR/root/opt/telmi/bin/"* 2>/dev/null || true
rm -f "$WORKDIR/root/opt/telmi/bin/storyTeller.real" 2>/dev/null || true
rm -rf "$WORKDIR/root/opt/telmi/audio-probe" 2>/dev/null || true

echo -n "${VERSION}" > "$WORKDIR/root/opt/telmi/telmiVersion/image-version.txt"
echo "${BUILD_ID}" > "$WORKDIR/root/opt/telmi/telmiVersion/build-id.txt"
echo "unified" > "$WORKDIR/root/opt/telmi/telmiVersion/profile.txt"
echo "multi-rev" > "$WORKDIR/root/opt/telmi/telmiVersion/variant.txt"

sync
fusermount -u "$WORKDIR/root"
sleep 1

echo "==> Reinjecte root..."
dd if="$ROOT_IMG" of="$OUTPUT_IMG" bs=512 seek="$ROOT_PART_START" conv=notrunc status=progress

sync
echo "$(basename "$OUTPUT_IMG")" > "$OUTPUT_DIR/LATEST.txt"
{
	echo "profile=unified-multi-rev"
	echo "version=${VERSION}"
	echo "build=${BUILD_ID}"
	echo "file=$(basename "$OUTPUT_IMG")"
	echo "base=$(basename "$BASE_IMG")"
	echo "default_rev=${DEFAULT_REV}"
	echo "revs=${REVS_LIST}"
} > "$OUTPUT_DIR/telmi-r36-${VERSION}.manifest.txt"

echo ""
echo "============================================================"
echo " OK $OUTPUT_IMG ($(du -h "$OUTPUT_IMG" | cut -f1))"
if [[ "$TELMI_OS_ONLY" == "1" ]]; then
	echo " Flash : Flash-Telmi-SD-OS-Only.bat  (slot droit)"
	echo " Contenu : Prepare-Content-SD.bat     (slot gauche)"
else
	echo " Flash : Flash-Telmi-SD.bat"
fi
echo " Puis  : Select-Telmi-REV.bat  (catalogue revs.json)"
echo "============================================================"
