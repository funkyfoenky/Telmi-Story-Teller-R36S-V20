#!/usr/bin/env bash
# Change le DTB panel d'une image / partition BOOT TelmiOS V30.
# N'affecte PAS les images V20.
#
# Usage :
#   bash scripts/switch-v30-dtb.sh output/telmi-r36-v30-0.1.0.img
#   bash scripts/switch-v30-dtb.sh output/telmi-r36-v30-0.1.0.img gameconsole-r36s.dtb
#   V30_DTB=rg351mp-kernel.dtb bash scripts/switch-v30-dtb.sh /mnt/d   # lettre BOOT montee
#
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export MTOOLS_SKIP_CHECK=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TELMI_R36="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib-telmi-v30-boot.sh
source "$SCRIPT_DIR/lib-telmi-v30-boot.sh"

TARGET="${1:-}"
[[ -n "$TARGET" ]] || {
	echo "Usage : $0 <image.img|dossier-BOOT|boot.fat> [dtb-name]"
	echo "DTB disponibles :"
	v30_dtb_list | sed 's/^/  /'
	exit 1
}
if [[ -n "${2:-}" ]]; then
	V30_DTB="$2"
fi
v30_validate_dtb "$V30_DTB"

BOOT_RESERVED_SECTORS="$V30_BOOT_RESERVED_SECTORS"
BOOT_PART_SECTORS="$V30_BOOT_PART_SECTORS"
VERSION="$(tr -d '[:space:]' < "$TELMI_R36/profiles/v30/VERSION" 2>/dev/null || echo "0.1.0")"
BUILD_ID="$(date '+%Y%m%d-%H%M')"

# Cas 1 : dossier BOOT Windows/Linux monte
if [[ -d "$TARGET" ]]; then
	echo "==> Patch dossier BOOT : $TARGET → $V30_DTB"
	for name in $(v30_dtb_list); do
		[[ -f "$V30_DTB_DIR/$name" ]] && cp -f "$V30_DTB_DIR/$name" "$TARGET/$name"
	done
	mkdir -p "$TARGET/extlinux"
	cat > "$TARGET/extlinux/extlinux.conf" <<EOF
LABEL TelmiOS-V30
  LINUX /Image
  FDT /${V30_DTB}
  INITRD /uInitrd
  APPEND earlyprintk console=ttyFIQ0 rw root=/dev/mmcblk1p2 rootfstype=ext4 loglevel=7 init=/sbin/init rootwait rootdelay=2 fsck.repair=yes fbcon=rotate:0 quiet splash plymouth.ignore-serial-consoles consoleblank=0

LABEL TelmiOS-V30-mmc0
  LINUX /Image
  FDT /${V30_DTB}
  INITRD /uInitrd
  APPEND earlyprintk console=ttyFIQ0 rw root=/dev/mmcblk0p2 rootfstype=ext4 loglevel=7 init=/sbin/init rootwait rootdelay=2 fsck.repair=yes fbcon=rotate:0 quiet splash plymouth.ignore-serial-consoles consoleblank=0
EOF
	if [[ -f "$TARGET/boot.ini" ]]; then
		sed -i -E \
			-e "s/(gameconsole-r36s|rg351mp-kernel|rk3326-rg351mp-linux|rk3326-r35s-linux)\\.dtb/${V30_DTB%.dtb}.dtb/g" \
			"$TARGET/boot.ini"
	fi
	echo "v30" > "$TARGET/TELMI-PROFILE.txt"
	echo -n "$VERSION" > "$TARGET/TELMI-VERSION.txt"
	echo "OK DTB=$V30_DTB sur $TARGET"
	exit 0
fi

# Cas 2 : fichier .img Telmi
if [[ -f "$TARGET" && "$TARGET" == *.img ]]; then
	WORKDIR="$(mktemp -d /tmp/telmi-v30-switch-XXXXXX)"
	cleanup() { rm -rf "$WORKDIR"; }
	trap cleanup EXIT
	BOOT_IMG="$WORKDIR/boot.fat"
	echo "==> Extraction BOOT de $TARGET..."
	dd if="$TARGET" of="$BOOT_IMG" bs=512 skip="$BOOT_RESERVED_SECTORS" \
		count="$BOOT_PART_SECTORS" status=none
	v30_patch_boot_fat "$BOOT_IMG" "$VERSION" "$BUILD_ID"
	dd if="$BOOT_IMG" of="$TARGET" bs=512 seek="$BOOT_RESERVED_SECTORS" conv=notrunc status=none
	sync
	echo "OK image patchée : $TARGET (DTB=$V30_DTB)"
	exit 0
fi

# Cas 3 : boot.fat nu
if [[ -f "$TARGET" ]]; then
	v30_patch_boot_fat "$TARGET" "$VERSION" "$BUILD_ID"
	echo "OK boot.fat patché : $TARGET (DTB=$V30_DTB)"
	exit 0
fi

echo "ERREUR : cible introuvable : $TARGET"
exit 1
