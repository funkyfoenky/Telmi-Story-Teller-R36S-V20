#!/usr/bin/env bash
# Fix ecran noir V30 : restaurer BOOT stock + patch root seulement
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export MTOOLS_SKIP_CHECK=1

TELMI="/mnt/c/Users/Utilisateur/Downloads/Tools/HelloWorld_R36S/Telmi-R36"
BASE="$TELMI/img_stock/Base_V30.img"
IMG="$TELMI/output/telmi-r36-v30-0.1.0.img"
BOOT_SKIP=32768
BOOT_COUNT=229376
W="$(mktemp -d /tmp/v30-fix-XXXXXX)"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT

echo "==> Restaure BOOT stock depuis Base_V30..."
dd if="$BASE" of="$W/boot.fat" bs=512 skip=$BOOT_SKIP count=$BOOT_COUNT status=progress

echo "==> Patch boot.ini (root UUID -> mmcblk1p2, DTB inchange)..."
mcopy -n -i "$W/boot.fat" ::/boot.ini "$W/boot.ini"
sed -i -E "s|root=UUID='[^']*'|root=/dev/mmcblk1p2 rootfstype=ext4|g" "$W/boot.ini"
sed -i -E 's|root=UUID=[^ "]+|root=/dev/mmcblk1p2 rootfstype=ext4|g' "$W/boot.ini"
echo "--- boot.ini ---"
grep -E 'root=|\.dtb' "$W/boot.ini"
mcopy -o -i "$W/boot.fat" "$W/boot.ini" ::/boot.ini

echo -n "0.1.0-fix1" > "$W/TELMI-VERSION.txt"
echo "v30-stock-dtb" > "$W/TELMI-PROFILE.txt"
printf 'TelmiOS-V30 fix1: stock DTB + root=mmcblk1p2\n' > "$W/TELMI-README.txt"
mcopy -o -i "$W/boot.fat" "$W/TELMI-VERSION.txt" ::/TELMI-VERSION.txt
mcopy -o -i "$W/boot.fat" "$W/TELMI-PROFILE.txt" ::/TELMI-PROFILE.txt
mcopy -o -i "$W/boot.fat" "$W/TELMI-README.txt" ::/TELMI-README.txt

# Variante mmc0 documentee
sed 's|mmcblk1p2|mmcblk0p2|g' "$W/boot.ini" > "$W/boot-mmc0.ini"
mcopy -o -i "$W/boot.fat" "$W/boot-mmc0.ini" ::/boot-mmc0.ini.txt

echo "==> Reinjecte BOOT..."
dd if="$W/boot.fat" of="$IMG" bs=512 seek=$BOOT_SKIP conv=notrunc status=progress
sync
echo "OK $IMG"
