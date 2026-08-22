#!/usr/bin/env bash
# Helpers boot TelmiOS profil V30 (DTB panels style R36S classique).
# Sourcé par assemble-telmi-v30*.sh — ne pas exécuter seul.
#
# Layout stock V30 (img_stock/Base_V30.img) :
#   Partition table : msdos (MBR) — PAS GPT comme V20
#   p1 BOOT : 32768s + 229376 secteurs (~112 Mo)
#   p2 root : 262144s ...
#
# Ne touche PAS au profil V20 (rf3536k3ka.dtb / GPT 500 Mo).

: "${TELMI_R36:?TELMI_R36 requis}"
# Defaut panel : gameconsole (meilleur rendu sur cette machine)
: "${V30_DTB:=gameconsole-r36s.dtb}"
# UUID root du stock V30 (Base_V30.img) — evite mmcblk0 vs mmcblk1
: "${V30_ROOT_UUID:=e139ce78-9841-40fe-8823-96a304a09859}"
# Ne pas ecraser les .dtb du BOOT stock sauf si V30_FORCE_DTB_FILES=1
: "${V30_FORCE_DTB_FILES:=0}"

V30_DTB_DIR="${V30_DTB_DIR:-$TELMI_R36/dtb_backup/R36S-V30_2025-11-18}"

# Geometrie BOOT stock V30 (ne pas reutiliser les constantes V20)
: "${V30_BOOT_RESERVED_SECTORS:=32768}"
: "${V30_BOOT_PART_SECTORS:=229376}"
: "${V30_ROOT_PART_START:=262144}"

v30_dtb_list() {
	printf '%s\n' \
		gameconsole-r36s.dtb \
		rk3326-rg351mp-linux.dtb \
		rg351mp-kernel.dtb
}

v30_validate_dtb() {
	local name="$1"
	local f="$V30_DTB_DIR/$name"
	[[ -f "$f" ]] || {
		echo "ERREUR V30 : DTB manquant : $f"
		echo "DTB connus :"
		v30_dtb_list | sed 's/^/  - /'
		return 1
	}
}

# Patch boot.ini : DTB + root device (UUID stock invalide apres recreate p2)
v30_rewrite_boot_ini() {
	local src="$1"
	local dst="$2"
	local dtb="$3"

	cp -f "$src" "$dst"
	# DTB panel
	sed -i -E \
		-e "s/(gameconsole-r36s|rg351mp-kernel|rk3326-rg351mp-linux|rk3326-r35s-linux)\\.dtb/${dtb%.dtb}.dtb/g" \
		"$dst"
	# Remplace root=... par UUID stock (fiable quel que soit mmcblk0/1)
	sed -i -E \
		-e "s|root=UUID='[^']*'|root=UUID='${V30_ROOT_UUID}'|g" \
		-e "s|root=UUID=[^ \"']+|root=UUID='${V30_ROOT_UUID}'|g" \
		-e "s|root=/dev/mmcblk[01]p[0-9]+( rootfstype=ext4)?|root=UUID='${V30_ROOT_UUID}'|g" \
		"$dst"
}

# Injecte DTB + patch boot.ini (+ extlinux de secours) dans une image FAT BOOT.
# Args : $1 = boot.fat  $2 = version  $3 = build_id
v30_patch_boot_fat() {
	local boot_fat="$1"
	local version="$2"
	local build_id="$3"
	local work name

	v30_validate_dtb "$V30_DTB" || return 1
	work="$(mktemp -d /tmp/telmi-v30-boot-XXXXXX)"

	echo "==> [V30] Patch BOOT (DTB=${V30_DTB}, root=UUID=${V30_ROOT_UUID})"
	if [[ "$V30_FORCE_DTB_FILES" == "1" ]]; then
		for name in $(v30_dtb_list); do
			if [[ -f "$V30_DTB_DIR/$name" ]]; then
				mcopy -o -i "$boot_fat" "$V30_DTB_DIR/$name" "::/$name" 2>/dev/null || true
				echo "    + ecrase $name (V30_FORCE_DTB_FILES=1)"
			fi
		done
	else
		echo "    (DTB fichiers stock conserves — pas d'ecrasement)"
	fi

	# boot.ini = chemin de boot principal sur V30 stock
	if mdir -i "$boot_fat" ::/boot.ini >/dev/null 2>&1; then
		mcopy -n -i "$boot_fat" ::/boot.ini "$work/boot.ini.orig" 2>/dev/null || true
		if [[ -f "$work/boot.ini.orig" ]]; then
			v30_rewrite_boot_ini "$work/boot.ini.orig" "$work/boot.ini" "$V30_DTB"
			mcopy -o -i "$boot_fat" "$work/boot.ini" ::/boot.ini
			echo "    + boot.ini → DTB=${V30_DTB}, root=mmcblk1p2"
			# Copie aussi boot.ini.default si present (ArkOS le regenererait sinon)
			if mdir -i "$boot_fat" ::/boot.ini.default >/dev/null 2>&1; then
				mcopy -o -i "$boot_fat" "$work/boot.ini" ::/boot.ini.default
			fi
		fi
	else
		echo "    ! boot.ini absent — creation minimale"
		cat > "$work/boot.ini" <<EOF
odroidgoa-uboot-config
setenv bootargs "root=/dev/mmcblk1p2 rootwait rw rootfstype=ext4 fsck.repair=yes net.ifnames=0 fbcon=rotate:0 console=/dev/ttyFIQ0 quiet splash plymouth.ignore-serial-consoles consoleblank=0 vt.global_cursor_default=0"
setenv loadaddr "0x02000000"
setenv initrd_loadaddr "0x01100000"
setenv dtb_loadaddr "0x01f00000"
load mmc 1:1 \${loadaddr} Image
load mmc 1:1 \${initrd_loadaddr} uInitrd
load mmc 1:1 \${dtb_loadaddr} ${V30_DTB}
booti \${loadaddr} \${initrd_loadaddr} \${dtb_loadaddr}
EOF
		mcopy -o -i "$boot_fat" "$work/boot.ini" ::/boot.ini
	fi

	# extlinux de secours (certains u-boot le lisent)
	mkdir -p "$work/extlinux"
	cat > "$work/extlinux/extlinux.conf" <<EOF
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
	mmd -i "$boot_fat" ::/extlinux 2>/dev/null || true
	mcopy -o -i "$boot_fat" "$work/extlinux/extlinux.conf" ::/extlinux/extlinux.conf

	cat > "$work/TELMI-README.txt" <<EOF
TelmiOS R36S profil V30

Version : ${version}
Build   : ${build_id}
DTB     : ${V30_DTB}
Layout  : MBR (BOOT ~112 Mo) — different de V20 GPT

Pour changer de panel :
  bash scripts/switch-v30-dtb.sh <image> <nom.dtb>
EOF
	echo -n "${version}" > "$work/TELMI-VERSION.txt"
	printf 'TelmiOS-V30 %s build %s dtb=%s\n' "$version" "$build_id" "$V30_DTB" \
		> "$work/telmi-runtime.log"
	echo "v30" > "$work/TELMI-PROFILE.txt"

	mcopy -o -i "$boot_fat" "$work/TELMI-README.txt" ::/TELMI-README.txt
	mcopy -o -i "$boot_fat" "$work/TELMI-VERSION.txt" ::/TELMI-VERSION.txt
	mcopy -o -i "$boot_fat" "$work/telmi-runtime.log" ::/telmi-runtime.log
	mcopy -o -i "$boot_fat" "$work/TELMI-PROFILE.txt" ::/TELMI-PROFILE.txt

	rm -rf "$work"
}
