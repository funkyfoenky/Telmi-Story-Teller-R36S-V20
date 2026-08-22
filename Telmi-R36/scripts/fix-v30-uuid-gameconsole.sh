#!/usr/bin/env bash
# Fix V30 ecran noir apres logos :
# 1) root=UUID stock (pas mmcblk1p2 — numerotation mmc variable)
# 2) DTB = gameconsole-r36s.dtb (meilleur rendu logos chez toi)
# 3) UUID du rootfs Telmi aligne sur le UUID stock
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export MTOOLS_SKIP_CHECK=1
export LD_LIBRARY_PATH="/mnt/c/Users/Utilisateur/Downloads/Tools/HelloWorld_R36S/Telmi-R36/.tools/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

TELMI="/mnt/c/Users/Utilisateur/Downloads/Tools/HelloWorld_R36S/Telmi-R36"
BASE="$TELMI/img_stock/Base_V30.img"
IMG="$TELMI/output/telmi-r36-v30-0.1.0.img"
FUSE2FS="$TELMI/.tools/fuse2fs"
STOCK_UUID="e139ce78-9841-40fe-8823-96a304a09859"
BOOT_SKIP=32768
BOOT_COUNT=229376
ROOT_SKIP=262144
ROOT_COUNT=$((1536 * 1024 * 1024 / 512))

W="$(mktemp -d /tmp/v30-fix2-XXXXXX)"
cleanup() {
	fusermount -u "$W/root" 2>/dev/null || true
	rm -rf "$W"
}
trap cleanup EXIT

echo "==> 1/3 BOOT stock + gameconsole + UUID root..."
dd if="$BASE" of="$W/boot.fat" bs=512 skip=$BOOT_SKIP count=$BOOT_COUNT status=progress
mcopy -n -i "$W/boot.fat" ::/boot.ini "$W/boot.ini"
# DTB -> gameconsole (tu as vu batterie/boot avec ce panel)
sed -i -E 's/(gameconsole-r36s|rg351mp-kernel|rk3326-rg351mp-linux|rk3326-r35s-linux)\.dtb/gameconsole-r36s.dtb/g' "$W/boot.ini"
# Garder / remettre UUID stock (ne PAS forcer mmcblkXp2)
if ! grep -q "root=UUID=" "$W/boot.ini"; then
	sed -i -E "s|root=/dev/mmcblk[01]p2 rootfstype=ext4|root=UUID='${STOCK_UUID}'|g" "$W/boot.ini"
	sed -i -E "s|root=/dev/mmcblk[01]p2|root=UUID='${STOCK_UUID}'|g" "$W/boot.ini"
fi
# Si on avait deja patché en mmcblk, remettre UUID
sed -i -E "s|root=/dev/mmcblk[01]p2( rootfstype=ext4)?|root=UUID='${STOCK_UUID}'|g" "$W/boot.ini"
grep -E 'root=|\.dtb' "$W/boot.ini"
mcopy -o -i "$W/boot.fat" "$W/boot.ini" ::/boot.ini
echo -n "0.1.0-fix2" > "$W/ver"
echo "v30-uuid+gameconsole" > "$W/prof"
mcopy -o -i "$W/boot.fat" "$W/ver" ::/TELMI-VERSION.txt
mcopy -o -i "$W/boot.fat" "$W/prof" ::/TELMI-PROFILE.txt
dd if="$W/boot.fat" of="$IMG" bs=512 seek=$BOOT_SKIP conv=notrunc status=progress

echo "==> 2/3 Aligner UUID du rootfs Telmi sur le stock..."
dd if="$IMG" of="$W/root.ext4" bs=512 skip=$ROOT_SKIP count=$ROOT_COUNT status=progress
tune2fs -U "$STOCK_UUID" "$W/root.ext4"
tune2fs -L rootfs "$W/root.ext4"
tune2fs -l "$W/root.ext4" | grep -E 'UUID|volume name'

echo "==> 3/3 fstab V30 (UUID + TELMI label, sans mmcblk force)..."
mkdir -p "$W/root"
"$FUSE2FS" -o fakeroot,rw "$W/root.ext4" "$W/root"
sleep 1
cat > "$W/root/etc/fstab" <<EOF
UUID=${STOCK_UUID}	/	ext4	defaults,noatime	0	1
LABEL=TELMI	/telmi	vfat	defaults,noatime,umask=0000,shortname=win95,nofail	0	2
/dev/mmcblk1p1	/boot	vfat	defaults,nofail,ro	0	0
/dev/mmcblk0p1	/boot	vfat	defaults,nofail,ro	0	0
proc		/proc	proc	defaults	0	0
devpts		/dev/pts	devpts	defaults,gid=5,mode=620,ptmxmode=0666	0	0
tmpfs		/dev/shm	tmpfs	mode=1777	0	0
tmpfs		/tmp		tmpfs	mode=1777	0	0
tmpfs		/run		tmpfs	mode=0755,nosuid,nodev	0	0
sysfs		/sys	sysfs	defaults	0	0
EOF
# Marqueur profil pour runtime
mkdir -p "$W/root/opt/telmi/telmiVersion"
echo "v30" > "$W/root/opt/telmi/telmiVersion/profile.txt"
echo -n "0.1.0-fix2" > "$W/root/opt/telmi/telmiVersion/image-version.txt"
sync
fusermount -u "$W/root"
sleep 1
dd if="$W/root.ext4" of="$IMG" bs=512 seek=$ROOT_SKIP conv=notrunc status=progress
sync
echo "OK fix2 applique : $IMG"
echo "Re-flashe cette image (gameconsole + root UUID stock)."
