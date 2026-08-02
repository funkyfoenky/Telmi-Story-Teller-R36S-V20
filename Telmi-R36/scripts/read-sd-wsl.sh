#!/usr/bin/env bash
# Lit les logs Telmi sur la carte SD montee via wsl --mount --bare
set -euo pipefail

DEV=""
for d in /dev/sd{e,f,g,h,i,d,c,b,a}; do
	[ -b "${d}" ] || continue
	[ -b "${d}2" ] || continue
	sz=$(blockdev --getsize64 "$d" 2>/dev/null || echo 0)
	if [ "$sz" -gt 40000000000 ] 2>/dev/null; then
		DEV="$d"
		break
	fi
done

if [ -z "$DEV" ]; then
	echo "ERREUR: carte SD non trouvee dans WSL"
	lsblk
	exit 1
fi

echo "Carte: $DEV"
mkdir -p /mnt/sd-boot /mnt/sd-root
umount /mnt/sd-boot /mnt/sd-root 2>/dev/null || true

mount -t vfat -o ro "${DEV}1" /mnt/sd-boot
mount -t ext4 -o ro "${DEV}2" /mnt/sd-root

echo "========== BOOT: telmi-runtime.log =========="
if [ -s /mnt/sd-boot/telmi-runtime.log ]; then
	cat /mnt/sd-boot/telmi-runtime.log
else
	echo "vide ou absent"
fi

echo "========== ROOT: telmi/logs/runtime.log =========="
if [ -f /mnt/sd-root/telmi/logs/runtime.log ]; then
	cat /mnt/sd-root/telmi/logs/runtime.log
else
	echo "absent"
fi

echo "========== extlinux =========="
head -6 /mnt/sd-boot/extlinux/extlinux.conf 2>/dev/null || echo "absent"

echo "========== init.d =========="
ls /mnt/sd-root/etc/init.d/ 2>/dev/null || true

umount /mnt/sd-boot /mnt/sd-root
