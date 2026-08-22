#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export MTOOLS_SKIP_CHECK=1
IMG=/mnt/c/Users/Utilisateur/Downloads/Tools/HelloWorld_R36S/Telmi-R36/img_stock/ArkOS_R35S-R36S_v2.0_11072025_MultiPanel.img
W=$(mktemp -d)
dd if="$IMG" of="$W/boot.fat" bs=512 skip=32768 count=229376 status=none
echo "=== firstboot.sh ==="
mcopy -n -i "$W/boot.fat" ::/firstboot.sh "$W/firstboot.sh" && cat "$W/firstboot.sh"
echo
echo "=== ScreenFiles ==="
mdir -i "$W/boot.fat" ::/ScreenFiles || true
for p in 0 1 2 3 4 5; do
  echo "--- Panel $p ---"
  mdir -i "$W/boot.fat" "::/ScreenFiles/Panel $p" 2>/dev/null || echo "(absent)"
done
# copy panel 4 dtb out
mkdir -p "$W/p4"
mcopy -n -i "$W/boot.fat" "::/ScreenFiles/Panel 4/*" "$W/p4/" 2>/dev/null || true
ls -la "$W/p4"
rm -rf "$W"
