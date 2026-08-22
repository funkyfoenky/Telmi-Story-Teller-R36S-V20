#!/usr/bin/env bash
# Assemble TelmiOS V30 sur base ArkOS MultiPanel (hybride).
#
# Pourquoi : le noyau stock/ArkOS est Linux 4.4.189 — le rootfs Buildroot Telmi
# (concu pour V20/5.x) plante apres les logos. On garde le root Ubuntu ArkOS
# compatible 4.4, et on injecte Telmi dans /opt/telmi avec ses libs.
#
# - Panel 4 force (ScreenFiles/Panel 4)
# - firstboot/expand desactive
# - Sortie : telmi-r36-v30-<VERSION>.img + LATEST-V30.txt
# - Ne touche PAS au profil V20
#
# Usage :
#   bash scripts/assemble-telmi-v30-arkos.sh
#   bash scripts/assemble-telmi-v30-arkos.sh /chemin/ArkOS_....img
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export MTOOLS_SKIP_CHECK=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TELMI_R36="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS_DIR="$TELMI_R36/.tools"
PROFILE_DIR="$TELMI_R36/profiles/v30"
OUTPUT_DIR="$TELMI_R36/output"
STAGING_BIN="$TELMI_R36/staging/v30/opt/telmi/bin"
[[ -d "$STAGING_BIN" ]] || STAGING_BIN="$TELMI_R36/staging/opt/telmi/bin"
# Sysroot libs Buildroot (si present)
BR_SYSROOT="${BR_SYSROOT:-$HOME/r36s-helloworld-build/buildroot-r36s/output/target}"

PANEL_NUM="${V30_PANEL:-4}"
STOCK_UUID="e139ce78-9841-40fe-8823-96a304a09859"

BOOT_RESERVED_SECTORS=32768
BOOT_PART_SECTORS=229376
ROOT_PART_START=262144
# Taille root ArkOS stock (~6700 Mo) — quasi plein, on agrandit pour Telmi
ROOT_PART_SECTORS_STOCK=13721600
ROOT_GROW_MB="${ROOT_GROW_MB:-1536}"
ROOT_PART_SECTORS=$((ROOT_PART_SECTORS_STOCK + ROOT_GROW_MB * 1024 * 1024 / 512))
ROOT_PART_SIZE_MB=$((ROOT_PART_SECTORS * 512 / 1024 / 1024))
TELMI_SIZE_MB="${TELMI_SIZE_MB:-512}"
IMG_SIZE_MB="${IMG_SIZE_MB:-$((16 + 112 + ROOT_PART_SIZE_MB + TELMI_SIZE_MB + 32))}"

VERSION="$(tr -d '[:space:]' < "$PROFILE_DIR/VERSION" 2>/dev/null || echo "0.2.0")"
BUILD_ID="$(date '+%Y%m%d-%H%M')"
OUTPUT_IMG="$OUTPUT_DIR/telmi-r36-v30-${VERSION}.img"

WORKING_IMG="${1:-}"
if [[ -z "$WORKING_IMG" ]]; then
	for cand in \
		"$TELMI_R36/img_stock/ArkOS_R35S-R36S_v2.0_11072025_MultiPanel.img" \
		"$TELMI_R36/img_stock/Base_V30_ArkOS.img"
	do
		[[ -f "$cand" ]] && WORKING_IMG="$cand" && break
	done
fi
[[ -f "$WORKING_IMG" ]] || { echo "ERREUR : image ArkOS MultiPanel introuvable"; exit 1; }
[[ -x "$TOOLS_DIR/fuse2fs" ]] || { echo "ERREUR : fuse2fs manquant"; exit 1; }
[[ -d "$STAGING_BIN" ]] || { echo "ERREUR : staging binaires Telmi manquant (make storyTeller)"; exit 1; }

export LD_LIBRARY_PATH="$TOOLS_DIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
FUSE2FS="$TOOLS_DIR/fuse2fs"

if [[ -f "$OUTPUT_IMG" ]]; then
	echo "ERREUR : $OUTPUT_IMG existe. Incrementez profiles/v30/VERSION."
	exit 1
fi

mkdir -p "$OUTPUT_DIR"
echo "============================================================"
echo " TelmiOS V30 HYBRIDE (ArkOS root + Telmi)"
echo " Base   : $WORKING_IMG"
echo " Panel  : $PANEL_NUM"
echo " Root   : ${ROOT_PART_SIZE_MB} Mo (Ubuntu ArkOS)"
echo " Sortie : $OUTPUT_IMG (~${IMG_SIZE_MB} Mo)"
echo "============================================================"

truncate -s "${IMG_SIZE_MB}MiB" "$OUTPUT_IMG"
dd if="$WORKING_IMG" of="$OUTPUT_IMG" bs=512 count="$BOOT_RESERVED_SECTORS" conv=notrunc status=none

TOTAL_SECTORS=$(($(stat -c%s "$OUTPUT_IMG") / 512))
ROOT_PART_END=$((ROOT_PART_START + ROOT_PART_SECTORS - 1))
TELMI_PART_START=$((ROOT_PART_END + 1))
TELMI_PART_END=$((TOTAL_SECTORS - 1))
BOOT_PART_END=$((BOOT_RESERVED_SECTORS + BOOT_PART_SECTORS - 1))

echo "==> MBR partitions..."
parted -s "$OUTPUT_IMG" mklabel msdos
parted -s "$OUTPUT_IMG" mkpart primary fat32 "${BOOT_RESERVED_SECTORS}s" "${BOOT_PART_END}s"
parted -s "$OUTPUT_IMG" mkpart primary ext4 "${ROOT_PART_START}s" "${ROOT_PART_END}s"
parted -s "$OUTPUT_IMG" mkpart primary fat32 "${TELMI_PART_START}s" "${TELMI_PART_END}s"
parted -s "$OUTPUT_IMG" set 1 boot on

WORKDIR="$(mktemp -d /tmp/telmi-v30-arkos-XXXXXX)"
cleanup() {
	fusermount -u "$WORKDIR/root" 2>/dev/null || true
	rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "==> Patch BOOT : panel ${PANEL_NUM} fixe + no firstboot..."
BOOT_IMG="$WORKDIR/boot.fat"
dd if="$WORKING_IMG" of="$BOOT_IMG" bs=512 skip="$BOOT_RESERVED_SECTORS" \
	count="$BOOT_PART_SECTORS" status=progress

# Copier DTB panel N a la racine BOOT (chemins attendus par boot.ini)
PANEL_DIR="::/ScreenFiles/Panel ${PANEL_NUM}"
mcopy -n -i "$BOOT_IMG" "${PANEL_DIR}/rk3326-r35s-linux.dtb" "$WORKDIR/rk3326-r35s-linux.dtb"
mcopy -n -i "$BOOT_IMG" "${PANEL_DIR}/rg351mp-kernel.dtb" "$WORKDIR/rg351mp-kernel.dtb" 2>/dev/null || true
mcopy -o -i "$BOOT_IMG" "$WORKDIR/rk3326-r35s-linux.dtb" ::/rk3326-r35s-linux.dtb
[[ -f "$WORKDIR/rg351mp-kernel.dtb" ]] && mcopy -o -i "$BOOT_IMG" "$WORKDIR/rg351mp-kernel.dtb" ::/rg351mp-kernel.dtb

# Desactive panel chooser + first expand
echo "disabled" > "$WORKDIR/nopanelchooser"
mcopy -o -i "$BOOT_IMG" "$WORKDIR/nopanelchooser" ::/nopanelchooser
printf '#!/bin/bash\n# TelmiOS : firstboot ArkOS desactive\nexit 0\n' > "$WORKDIR/firstboot.sh"
mcopy -o -i "$BOOT_IMG" "$WORKDIR/firstboot.sh" ::/firstboot.sh

# boot.ini simplifie : DTB panel deja copie a la racine BOOT
cat > "$WORKDIR/boot.ini" <<EOF
odroidgoa-uboot-config

setenv loadaddr "0x02000000"
setenv initrd_loadaddr "0x01100000"
setenv dtb_loadaddr "0x01f00000"

setenv bootargs "root=UUID='${STOCK_UUID}' rootwait rw fsck.repair=yes net.ifnames=0 fbcon=rotate:0 console=/dev/ttyFIQ0 quiet splash plymouth.ignore-serial-consoles consoleblank=0 panel=${PANEL_NUM}"

load mmc 1:1 \${loadaddr} Image
load mmc 1:1 \${initrd_loadaddr} uInitrd
load mmc 1:1 \${dtb_loadaddr} rk3326-r35s-linux.dtb

booti \${loadaddr} \${initrd_loadaddr} \${dtb_loadaddr}
sleep 3
reset
EOF
mcopy -o -i "$BOOT_IMG" "$WORKDIR/boot.ini" ::/boot.ini

echo -n "${VERSION}" > "$WORKDIR/TELMI-VERSION.txt"
echo "v30-arkos-hybrid-p${PANEL_NUM}" > "$WORKDIR/TELMI-PROFILE.txt"
printf 'TelmiOS V30 hybrid ArkOS panel %s build %s\n' "$PANEL_NUM" "$BUILD_ID" > "$WORKDIR/TELMI-README.txt"
mcopy -o -i "$BOOT_IMG" "$WORKDIR/TELMI-VERSION.txt" ::/TELMI-VERSION.txt
mcopy -o -i "$BOOT_IMG" "$WORKDIR/TELMI-PROFILE.txt" ::/TELMI-PROFILE.txt
mcopy -o -i "$BOOT_IMG" "$WORKDIR/TELMI-README.txt" ::/TELMI-README.txt

echo "==> Ecriture BOOT patche dans l'image..."
dd if="$BOOT_IMG" of="$OUTPUT_IMG" bs=512 seek="$BOOT_RESERVED_SECTORS" conv=notrunc status=progress

echo "==> Extraction root Ubuntu ArkOS (stock ${ROOT_PART_SECTORS_STOCK} secteurs + grow ${ROOT_GROW_MB} Mo — long)..."
ROOT_IMG="$WORKDIR/root.ext"
dd if="$WORKING_IMG" of="$ROOT_IMG" bs=512 skip="$ROOT_PART_START" \
	count="$ROOT_PART_SECTORS_STOCK" status=progress
# Agrandir le fichier + filesystem (ArkOS root est quasi plein)
echo "==> Agrandissement root +${ROOT_GROW_MB} Mo..."
truncate -s "$((ROOT_PART_SECTORS * 512))" "$ROOT_IMG"
e2fsck -fy "$ROOT_IMG" || true
resize2fs "$ROOT_IMG" || { echo "ERREUR resize2fs"; exit 1; }
e2fsck -fy "$ROOT_IMG" || true
# Assurer UUID
tune2fs -U "$STOCK_UUID" "$ROOT_IMG" 2>/dev/null || true
tune2fs -L rootfs "$ROOT_IMG" 2>/dev/null || true

echo "==> Injection Telmi dans root Ubuntu..."

mkdir -p "$WORKDIR/root"
"$FUSE2FS" -o fakeroot,rw "$ROOT_IMG" "$WORKDIR/root"
sleep 2

# Liberer un peu d espace (caches / demos) avant injection
echo "    Liberation espace ArkOS (caches)..."
rm -rf "$WORKDIR/root/var/cache/apt/archives/"*.deb 2>/dev/null || true
rm -rf "$WORKDIR/root/var/tmp/"* 2>/dev/null || true
# Logs volumineux
find "$WORKDIR/root/var/log" -type f -name '*.log' -exec truncate -s 0 {} \; 2>/dev/null || true
df -h "$WORKDIR/root" || true

mkdir -p "$WORKDIR/root/opt/telmi/bin" "$WORKDIR/root/opt/telmi/lib" \
	"$WORKDIR/root/opt/telmi/telmiVersion" "$WORKDIR/root/telmi" \
	"$WORKDIR/root/etc/init.d"

# Binaires Telmi
cp -a "$STAGING_BIN/"* "$WORKDIR/root/opt/telmi/bin/" 2>/dev/null || true
chmod +x "$WORKDIR/root/opt/telmi/bin/"* 2>/dev/null || true

# Libs depuis sysroot Buildroot (SDL, etc.)
if [[ -d "$BR_SYSROOT/usr/lib" ]]; then
	echo "    Copie libs Buildroot vers /opt/telmi/lib..."
	# Copie selective des libs courantes Telmi/SDL
	for pat in 'libSDL2*' 'libasound*' 'libpng*' 'libz.so*' 'libfreetype*' \
		'libGLESv2*' 'libEGL*' 'libgbm*' 'libdrm*' 'libffi*' 'libstdc++*' \
		'libgcc_s*' 'libpthread*' 'libdl*' 'librt*' 'libm.so*' 'libc.so*' \
		'ld-linux*' 'libGLdispatch*' 'libglapi*' 'libexpat*' 'libX11*' \
		'libxcb*' 'libXau*' 'libXdmcp*' 'libwayland*' ; do
		cp -a "$BR_SYSROOT"/lib/$pat "$WORKDIR/root/opt/telmi/lib/" 2>/dev/null || true
		cp -a "$BR_SYSROOT"/usr/lib/$pat "$WORKDIR/root/opt/telmi/lib/" 2>/dev/null || true
	done
	# linker
	cp -a "$BR_SYSROOT"/lib/ld-linux-aarch64.so.1 "$WORKDIR/root/opt/telmi/lib/" 2>/dev/null || true
fi

# Assets UI si presents
if [[ -d "$TELMI_R36/assets/res" ]]; then
	mkdir -p "$WORKDIR/root/opt/telmi/res"
	cp -a "$TELMI_R36/assets/res/"* "$WORKDIR/root/opt/telmi/res/" 2>/dev/null || true
fi

# Wrapper demarrage
cat > "$WORKDIR/root/opt/telmi/bin/telmi-start.sh" <<'WRAP'
#!/bin/bash
export PATH=/opt/telmi/bin:$PATH
export TELMI_ROOT=/opt/telmi
export SDL_AUDIODRIVER=alsa
# 4.4 : tenter fbcon puis kmsdrm
export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-fbcon}"
export SDL_FBDEV=/dev/fb0
export SDL_RENDER_DRIVER=software
mkdir -p /telmi/logs /telmi/Stories /telmi/Music /telmi/Saves
# Monter partition TELMI si presente
if ! mountpoint -q /telmi 2>/dev/null; then
  mount -L TELMI /telmi 2>/dev/null || mount /dev/mmcblk1p3 /telmi 2>/dev/null || mount /dev/mmcblk0p3 /telmi 2>/dev/null || true
fi
mkdir -p /telmi/.tmp_update
mount --bind /opt/telmi /telmi/.tmp_update 2>/dev/null || true
echo 0 > /sys/class/graphics/fb0/blank 2>/dev/null || true
cd /opt/telmi
exec >>/telmi/logs/runtime.log 2>&1
echo "[telmi-hybrid] start $(date) SDL_VIDEODRIVER=$SDL_VIDEODRIVER"

# Binaires Buildroot : linker + libs du sysroot (pas le glibc Ubuntu)
run_telmi() {
  local bin="$1"; shift
  if [[ -x /opt/telmi/lib/ld-linux-aarch64.so.1 ]]; then
    /opt/telmi/lib/ld-linux-aarch64.so.1 --library-path /opt/telmi/lib "/opt/telmi/bin/$bin" "$@"
  else
    LD_LIBRARY_PATH=/opt/telmi/lib:${LD_LIBRARY_PATH:-} "/opt/telmi/bin/$bin" "$@"
  fi
}

run_telmi bootScreen Boot || true
if ! run_telmi storyTeller; then
  echo "[telmi-hybrid] storyTeller fbcon fail, try kmsdrm"
  export SDL_VIDEODRIVER=kmsdrm
  unset SDL_FBDEV
  run_telmi storyTeller || echo "[telmi-hybrid] storyTeller kmsdrm fail"
fi
WRAP
chmod +x "$WORKDIR/root/opt/telmi/bin/telmi-start.sh"

echo -n "$VERSION" > "$WORKDIR/root/opt/telmi/telmiVersion/image-version.txt"
echo "$BUILD_ID" > "$WORKDIR/root/opt/telmi/telmiVersion/build-id.txt"
echo "v30-arkos-hybrid" > "$WORKDIR/root/opt/telmi/telmiVersion/profile.txt"

# Init script prioritaire (BusyBox/sysv ou appele depuis rc.local)
cat > "$WORKDIR/root/etc/init.d/S99telmi-hybrid" <<'INIT'
#!/bin/sh
case "$1" in
  start)
    /opt/telmi/bin/telmi-start.sh &
    ;;
  stop) ;;
  *) exit 1 ;;
esac
exit 0
INIT
chmod +x "$WORKDIR/root/etc/init.d/S99telmi-hybrid"

# rc.local fallback (Ubuntu)
if [[ -f "$WORKDIR/root/etc/rc.local" ]]; then
	sed -i '/telmi-start/d' "$WORKDIR/root/etc/rc.local"
	sed -i 's|^exit 0|/opt/telmi/bin/telmi-start.sh \&\nexit 0|' "$WORKDIR/root/etc/rc.local"
elif [[ -d "$WORKDIR/root/etc" ]]; then
	printf '#!/bin/bash\n/opt/telmi/bin/telmi-start.sh &\nexit 0\n' > "$WORKDIR/root/etc/rc.local"
	chmod +x "$WORKDIR/root/etc/rc.local"
fi

# Detourner EmulationStation / autostart ArkOS vers Telmi
find "$WORKDIR/root/etc/systemd" "$WORKDIR/root/lib/systemd" \
	"$WORKDIR/root/usr/lib/systemd" -name '*emulationstation*' 2>/dev/null | while read -r unit; do
	cp -a "$unit" "${unit}.telmi-bak" 2>/dev/null || true
	printf '[Unit]\nDescription=TelmiOS hybrid\nAfter=local-fs.target\n\n[Service]\nType=simple\nExecStart=/opt/telmi/bin/telmi-start.sh\nRestart=on-failure\n\n[Install]\nWantedBy=multi-user.target\n' > "$unit"
done
for f in \
	"$WORKDIR/root/usr/bin/emulationstation" \
	"$WORKDIR/root/usr/local/bin/emulationstation" \
	"$WORKDIR/root/usr/bin/emulationstation.sh"
do
	[[ -e "$f" ]] || continue
	cp -a "$f" "$f.telmi-bak" 2>/dev/null || true
	printf '#!/bin/bash\nexec /opt/telmi/bin/telmi-start.sh\n' > "$f"
	chmod +x "$f"
done
for f in "$WORKDIR/root/home/ark/.bashrc" "$WORKDIR/root/home/ark/.profile" \
	"$WORKDIR/root/home/ark/.bash_profile" "$WORKDIR/root/home/ark/.xinitrc" \
	"$WORKDIR/root/etc/profile.d/"*.sh
do
	[[ -f "$f" ]] || continue
	if grep -qE 'emulationstation|EmulationStation' "$f" 2>/dev/null; then
		cp -a "$f" "$f.telmi-bak" 2>/dev/null || true
		sed -i -E 's|[^#]*[Ee]mulation[Ss]tation[^;]*|/opt/telmi/bin/telmi-start.sh|g' "$f"
	fi
done
# Service systemd Telmi (si systemd present)
if [[ -d "$WORKDIR/root/etc/systemd/system" ]]; then
	printf '[Unit]\nDescription=TelmiOS V30 hybrid\nAfter=local-fs.target multi-user.target\n\n[Service]\nType=simple\nExecStart=/opt/telmi/bin/telmi-start.sh\nRestart=on-failure\nRestartSec=2\n\n[Install]\nWantedBy=multi-user.target\n' \
		> "$WORKDIR/root/etc/systemd/system/telmi-hybrid.service"
	mkdir -p "$WORKDIR/root/etc/systemd/system/multi-user.target.wants"
	ln -sfn ../telmi-hybrid.service \
		"$WORKDIR/root/etc/systemd/system/multi-user.target.wants/telmi-hybrid.service"
fi
# Log des points d'entree trouves
{
	echo "[assemble] ES/telmi hooks:"
	ls -la "$WORKDIR/root/usr/bin/emulationstation" "$WORKDIR/root/usr/local/bin/emulationstation" 2>/dev/null || true
	ls "$WORKDIR/root/etc/systemd/system/"*emulation* "$WORKDIR/root/etc/systemd/system/telmi-hybrid.service" 2>/dev/null || true
	head -5 "$WORKDIR/root/etc/rc.local" 2>/dev/null || true
} > "$WORKDIR/root/opt/telmi/telmiVersion/autostart-hooks.txt" 2>/dev/null || true

# fstab : garder UUID root, ajouter TELMI
if [[ -f "$WORKDIR/root/etc/fstab" ]]; then
	grep -q 'LABEL=TELMI' "$WORKDIR/root/etc/fstab" || \
		echo 'LABEL=TELMI /telmi vfat defaults,noatime,umask=0000,nofail 0 0' >> "$WORKDIR/root/etc/fstab"
fi

sync
fusermount -u "$WORKDIR/root"
sleep 2

echo "==> Reinjecte root..."
dd if="$ROOT_IMG" of="$OUTPUT_IMG" bs=512 seek="$ROOT_PART_START" conv=notrunc status=progress

echo "==> Partition TELMI..."
TELMI_IMG="$WORKDIR/telmi.fat"
mkfs.vfat -F 32 -n TELMI -C "$TELMI_IMG" $((TELMI_SIZE_MB * 1024)) >/dev/null
mmd -i "$TELMI_IMG" ::/Stories ::/Music ::/Games ::/Saves ::/logs
for d in gb gbc gba nes md snes psx; do
	mmd -i "$TELMI_IMG" "::/Games/$d" 2>/dev/null || true
done
dd if="$TELMI_IMG" of="$OUTPUT_IMG" bs=512 seek="$TELMI_PART_START" conv=notrunc status=progress

sync
echo "$(basename "$OUTPUT_IMG")" > "$OUTPUT_DIR/LATEST-V30.txt"
{
	echo "profile=v30-arkos-hybrid"
	echo "version=${VERSION}"
	echo "panel=${PANEL_NUM}"
	echo "build=${BUILD_ID}"
	echo "file=$(basename "$OUTPUT_IMG")"
	echo "base=$(basename "$WORKING_IMG")"
} > "$OUTPUT_DIR/telmi-r36-v30-${VERSION}.manifest.txt"

echo ""
echo "============================================================"
echo " OK $OUTPUT_IMG"
echo " Panel ${PANEL_NUM} fixe, firstboot off, root Ubuntu+Telmi"
echo " Flash avec Rufus / Flash-Telmi-SD-V30.bat"
echo "============================================================"
