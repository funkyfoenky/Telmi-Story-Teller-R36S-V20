#!/usr/bin/env bash
# Injecte telmi-boot-diag.sh + hook S99telmi dans le rootfs ext4 d'une SD ou .img Telmi.
# Utile si image flashée = 0.6.6 (sans boot-diag dans rootfs) mais BOOT déjà préparé.
#
# Usage :
#   sudo bash scripts/inject-boot-diag-into-sd.sh /dev/sdX
#   sudo bash scripts/inject-boot-diag-into-sd.sh output/telmi-r36-0.6.6.img
#
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TELMI_R36="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS_DIR="$TELMI_R36/.tools"
ROOT_PART_START=1056768
ROOT_PART_SECTORS=$((1536 * 1024 * 1024 / 512))

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
	echo "Usage: sudo $0 /dev/sdX|chemin.img"
	exit 1
fi

FUSE2FS="$TOOLS_DIR/fuse2fs"
[[ -x "$FUSE2FS" ]] || FUSE2FS="$(command -v fuse2fs || true)"
[[ -n "$FUSE2FS" ]] || { echo "ERREUR : fuse2fs introuvable"; exit 1; }

DIAG_SH="$TELMI_R36/overlay/opt/telmi/bin/telmi-boot-diag.sh"
PANEL_DIAG_SH="$TELMI_R36/overlay/opt/telmi/bin/telmi-panel-diag.sh"
PSTORE_SH="$TELMI_R36/overlay/opt/telmi/bin/telmi-export-pstore.sh"
S05="$TELMI_R36/overlay/etc/init.d/S05boot"
[[ -f "$DIAG_SH" ]] || { echo "ERREUR : $DIAG_SH manquant"; exit 1; }
[[ -f "$PANEL_DIAG_SH" ]] || { echo "ERREUR : $PANEL_DIAG_SH manquant"; exit 1; }
[[ -f "$PSTORE_SH" ]] || { echo "ERREUR : $PSTORE_SH manquant"; exit 1; }
[[ -f "$S05" ]] || { echo "ERREUR : $S05 manquant"; exit 1; }

WORKDIR="$(mktemp -d /tmp/telmi-inject-bd-XXXXXX)"
cleanup() {
	fusermount -u "$WORKDIR/mnt" 2>/dev/null || true
	rm -rf "$WORKDIR"
}
trap cleanup EXIT

if [[ -f "$TARGET" && "$TARGET" == *.img ]]; then
	echo "==> Extraction partition root depuis $TARGET"
	dd if="$TARGET" of="$WORKDIR/root.ext" bs=512 skip="$ROOT_PART_START" \
		count="$ROOT_PART_SECTORS" status=none
	ROOT_DEV="$WORKDIR/root.ext"
	WRITE_BACK=1
elif [[ -b "$TARGET" ]]; then
	echo "==> Partition root sur $TARGET"
	# p2 = root ext4 (p1 = BOOT)
	ROOT_DEV="${TARGET}2"
	if [[ ! -b "$ROOT_DEV" ]]; then
		ROOT_DEV="${TARGET}p2"
	fi
	[[ -b "$ROOT_DEV" ]] || { echo "ERREUR : partition root introuvable"; exit 1; }
	WRITE_BACK=0
else
	echo "ERREUR : cible invalide ($TARGET)"
	exit 1
fi

mkdir -p "$WORKDIR/mnt"
"$FUSE2FS" -o fakeroot,rw "$ROOT_DEV" "$WORKDIR/mnt"
sleep 1

echo "==> Copie scripts diag..."
mkdir -p "$WORKDIR/mnt/opt/telmi/bin"
cp -f "$DIAG_SH" "$WORKDIR/mnt/opt/telmi/bin/telmi-boot-diag.sh"
cp -f "$PANEL_DIAG_SH" "$WORKDIR/mnt/opt/telmi/bin/telmi-panel-diag.sh"
cp -f "$PSTORE_SH" "$WORKDIR/mnt/opt/telmi/bin/telmi-export-pstore.sh"
chmod +x "$WORKDIR/mnt/opt/telmi/bin/telmi-boot-diag.sh" \
	"$WORKDIR/mnt/opt/telmi/bin/telmi-panel-diag.sh" \
	"$WORKDIR/mnt/opt/telmi/bin/telmi-export-pstore.sh"
for _f in "$WORKDIR/mnt/opt/telmi/bin/telmi-"*.sh; do
	sed -i 's/\r$//' "$_f"
done

echo "==> Patch S05boot + S99telmi..."
mkdir -p "$WORKDIR/mnt/etc/init.d"
cp -f "$S05" "$WORKDIR/mnt/etc/init.d/S05boot"
chmod +x "$WORKDIR/mnt/etc/init.d/S05boot"
sed -i 's/\r$//' "$WORKDIR/mnt/etc/init.d/S05boot"
S99="$TELMI_R36/overlay/etc/init.d/S99telmi"
cp -f "$S99" "$WORKDIR/mnt/etc/init.d/S99telmi"
chmod +x "$WORKDIR/mnt/etc/init.d/S99telmi"
sed -i 's/\r$//' "$WORKDIR/mnt/etc/init.d/S99telmi"

sync
fusermount -u "$WORKDIR/mnt"
sleep 1

if [[ "${WRITE_BACK:-0}" == "1" ]]; then
	echo "==> Reinjection root dans $TARGET"
	dd if="$WORKDIR/root.ext" of="$TARGET" bs=512 seek="$ROOT_PART_START" conv=notrunc status=progress
fi

echo "OK — boot-diag injecté. Sur BOOT : lancez Prepare-Y3506-Bootdiag.bat puis bootez."
