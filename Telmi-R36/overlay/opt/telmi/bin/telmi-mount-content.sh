#!/bin/sh
# Montage partition contenu Telmi : dual-SD (carte non-OS / slot gauche) puis fallback p3 OS.
# Usage : telmi-mount-content.sh mount|setup|status
#
# BusyBox blkid n a PAS -s LABEL -o value ni -L TELMI -o device.
# Parser la ligne complete : /dev/xxx: LABEL="TELMI" UUID="..." TYPE="vfat"

TELMI_CONTENT_MODE_FILE=/run/telmi-content-mode
TELMI_CONTENT_LOG=/boot/telmi-content.log

log_telmi() {
	logger -t telmi "$*" 2>/dev/null || true
	echo "[telmi-mount] $*"
	if [ -d /boot ] && { mountpoint -q /boot 2>/dev/null || [ -w /boot ]; }; then
		echo "$(date '+%H:%M:%S') $*" >> "$TELMI_CONTENT_LOG" 2>/dev/null || true
	fi
}

# Extraire un champ de blkid BusyBox (LABEL / TYPE)
blkid_field() {
	_dev="$1"
	_key="$2"
	_line=$(blkid "$_dev" 2>/dev/null || true)
	[ -n "$_line" ] || return 1
	echo "$_line" | sed -n "s/.*${_key}=\"\([^\"]*\)\".*/\1/p"
}

blkid_label() { blkid_field "$1" LABEL; }
blkid_type()  { blkid_field "$1" TYPE; }

# Dev avec LABEL=TELMI (BusyBox : grep la sortie brute)
blkid_dev_by_label() {
	_want="$1"
	blkid 2>/dev/null | while IFS= read -r _line; do
		case "$_line" in
			*"LABEL=\"${_want}\""*)
				echo "$_line" | sed -n 's/^\([^:]*\):.*/\1/p'
				return 0
				;;
		esac
	done
}

ensure_sdcard_link() {
	mkdir -p /mnt /telmi
	if [ ! -L /mnt/SDCARD ] && [ ! -e /mnt/SDCARD ]; then
		ln -sf /telmi /mnt/SDCARD
	elif [ -d /mnt/SDCARD ] && [ ! -L /mnt/SDCARD ]; then
		rmdir /mnt/SDCARD 2>/dev/null && ln -sf /telmi /mnt/SDCARD
	fi
}

get_os_mmc_base() {
	_src=""
	if command -v findmnt >/dev/null 2>&1; then
		_src=$(findmnt -n -o SOURCE / 2>/dev/null || true)
	fi
	if [ -z "$_src" ] || [ "$_src" = "/dev/root" ]; then
		_src=$(awk '$2=="/" {print $1; exit}' /proc/mounts 2>/dev/null || true)
	fi
	case "$_src" in
		/dev/mmcblk*p*)
			echo "$_src" | sed -n 's|^/dev/\(mmcblk[0-9]*\)p[0-9]*|\1|p'
			return 0
			;;
	esac
	_dev=$(blkid_dev_by_label rootfs)
	case "$_dev" in
		/dev/mmcblk*p*)
			echo "$_dev" | sed -n 's|^/dev/\(mmcblk[0-9]*\)p[0-9]*|\1|p'
			return 0
			;;
	esac
	_dev=$(blkid_dev_by_label BOOT)
	case "$_dev" in
		/dev/mmcblk*p*)
			echo "$_dev" | sed -n 's|^/dev/\(mmcblk[0-9]*\)p[0-9]*|\1|p'
			return 0
			;;
	esac
	return 1
}

part_on_mmc() {
	_dev="$1"
	_mmc="$2"
	case "$_dev" in
		"/dev/${_mmc}"p[0-9]*|"/dev/${_mmc}") return 0 ;;
	esac
	return 1
}

is_os_system_part() {
	_dev="$1"
	_lbl=$(blkid_label "$_dev")
	case "$_lbl" in
		BOOT|rootfs|ROOTFS) return 0 ;;
	esac
	_fs=$(blkid_type "$_dev")
	[ "$_fs" = "ext4" ] && return 0
	return 1
}

try_mount_vfat() {
	_dev="$1"
	[ -b "$_dev" ] || return 1
	if is_os_system_part "$_dev"; then
		return 1
	fi
	# Options simples d abord (BusyBox mount refuse parfois umask/shortname)
	if mount -t vfat "$_dev" /telmi 2>/tmp/telmi-mount.err; then
		return 0
	fi
	if mount -t vfat -o rw,umask=0000 "$_dev" /telmi 2>/tmp/telmi-mount.err; then
		return 0
	fi
	if mount -t vfat -o rw,umask=0000,shortname=win95,utf8 "$_dev" /telmi 2>/tmp/telmi-mount.err; then
		return 0
	fi
	if mount -t msdos "$_dev" /telmi 2>/tmp/telmi-mount.err; then
		return 0
	fi
	_err=$(cat /tmp/telmi-mount.err 2>/dev/null | tr '\n' ' ')
	log_telmi "WARN: mount echoue $_dev ${_err}"
	return 1
}

part_label_is_telmi() {
	_lbl=$(blkid_label "$1")
	[ "$_lbl" = "TELMI" ]
}

default_wait_max() {
	# Surcharge explicite (runtime retry court, debug, etc.)
	if [ -n "${TELMI_WAIT_MAX+x}" ] && [ -n "$TELMI_WAIT_MAX" ]; then
		echo "$TELMI_WAIT_MAX"
		return 0
	fi
	_rev=""
	[ -f /boot/TELMI-REV.txt ] && _rev=$(tr -d '\r\n ' < /boot/TELMI-REV.txt)
	case "$_rev" in
		v30*|V30*|y3506*|Y3506*) echo 20 ;;
		*) echo 8 ;;
	esac
}

is_fatish() {
	_fs="$1"
	case "$_fs" in
		vfat|msdos|fat|fat32|"") return 0 ;;
	esac
	return 1
}

log_mmc_inventory() {
	_os=$(get_os_mmc_base) || _os="?"
	log_telmi "scan: root_os_mmc=${_os}"
	_hosts=""
	for _h in /sys/class/mmc_host/mmc*; do
		[ -d "$_h" ] || continue
		_hosts="$_hosts $(basename "$_h")"
	done
	log_telmi "  mmc_hosts:${_hosts:- none}"

	for _h in /sys/class/mmc_host/mmc*; do
		[ -d "$_h" ] || continue
		_hn=$(basename "$_h")
		_cards=0
		_blocks=0
		_detail=""
		for _card in "$_h"/mmc*:*; do
			[ -d "$_card" ] || continue
			_cards=$((_cards + 1))
			_cid=$(basename "$_card")
			_type=$(cat "$_card/type" 2>/dev/null || echo ?)
			_blk=""
			if [ -d "$_card/block" ]; then
				for _b in "$_card/block"/mmcblk*; do
					[ -e "$_b" ] || continue
					_blocks=$((_blocks + 1))
					_blk=" blk=$(basename "$_b")"
				done
			fi
			_detail="${_detail} ${_cid}(type=${_type}${_blk})"
		done
		log_telmi "  host ${_hn}: cards=${_cards} blocks=${_blocks}${_detail}"
	done

	_found=0
	for _sys in /sys/block/mmcblk0 /sys/block/mmcblk1 /sys/block/mmcblk2 /sys/block/mmcblk3; do
		[ -d "$_sys" ] || continue
		_found=1
		_mmc=$(basename "$_sys")
		_note="candidate"
		[ "$_mmc" = "$_os" ] && _note="OS"
		_parts=""
		for _p in /dev/${_mmc}p1 /dev/${_mmc}p2 /dev/${_mmc}p3 /dev/${_mmc}p4; do
			[ -b "$_p" ] || continue
			_lbl=$(blkid_label "$_p")
			_fs=$(blkid_type "$_p")
			_parts="${_parts} $(basename "$_p")(fs=${_fs:--},lbl=${_lbl:--})"
		done
		log_telmi "  ${_mmc} (${_note})${_parts}"
	done
	[ "$_found" -eq 0 ] && log_telmi "  (aucun mmcblk*)"
	_lbldev=$(blkid_dev_by_label TELMI)
	[ -n "$_lbldev" ] && log_telmi "  LABEL=TELMI => $_lbldev"
}

mount_by_telmi_label_external() {
	_os=$(get_os_mmc_base) || _os=""
	_dev=$(blkid_dev_by_label TELMI)
	[ -n "$_dev" ] || return 1
	if [ -n "$_os" ] && part_on_mmc "$_dev" "$_os"; then
		return 1
	fi
	if try_mount_vfat "$_dev"; then
		echo external > "$TELMI_CONTENT_MODE_FILE"
		log_telmi "content=external dev=$_dev (label TELMI)"
		return 0
	fi
	return 1
}

mount_external_content() {
	_os=$(get_os_mmc_base) || _os=""

	if mount_by_telmi_label_external; then
		return 0
	fi

	for _mmc in mmcblk0 mmcblk1 mmcblk2 mmcblk3; do
		[ -d "/sys/block/$_mmc" ] || continue
		[ "$_mmc" = "$_os" ] && continue

		for _p in "${_mmc}p1" "${_mmc}p2" "${_mmc}p3" "${_mmc}p4"; do
			_dev="/dev/$_p"
			[ -b "$_dev" ] || continue
			is_os_system_part "$_dev" && continue
			_fs=$(blkid_type "$_dev")
			_lbl=$(blkid_label "$_dev")
			# p1 externe : toujours tenter (BusyBox TYPE parfois vide)
			if [ "$_lbl" = "TELMI" ] || [ "$_p" = "${_mmc}p1" ] || is_fatish "$_fs"; then
				log_telmi "try $_dev fs=${_fs:--} lbl=${_lbl:--}"
				if try_mount_vfat "$_dev"; then
					echo external > "$TELMI_CONTENT_MODE_FILE"
					log_telmi "content=external dev=$_dev"
					return 0
				fi
			fi
		done
		if [ -b "/dev/$_mmc" ]; then
			if try_mount_vfat "/dev/$_mmc"; then
				echo external > "$TELMI_CONTENT_MODE_FILE"
				log_telmi "content=external dev=/dev/$_mmc (whole)"
				return 0
			fi
		fi
	done
	return 1
}

mount_internal_content() {
	_os=$(get_os_mmc_base) || _os=""

	if [ -n "$_os" ] && try_mount_vfat "/dev/${_os}p3"; then
		echo internal > "$TELMI_CONTENT_MODE_FILE"
		log_telmi "content=internal dev=/dev/${_os}p3"
		return 0
	fi

	for _try in mmcblk1p3 mmcblk0p3 mmcblk2p3; do
		_dev="/dev/$_try"
		[ -b "$_dev" ] || continue
		if [ -n "$_os" ] && ! part_on_mmc "$_dev" "$_os"; then
			continue
		fi
		if try_mount_vfat "$_dev"; then
			echo internal > "$TELMI_CONTENT_MODE_FILE"
			log_telmi "content=internal dev=$_dev"
			return 0
		fi
	done

	_dev=$(blkid_dev_by_label TELMI)
	if [ -n "$_os" ] && [ -n "$_dev" ] && part_on_mmc "$_dev" "$_os"; then
		if try_mount_vfat "$_dev"; then
			echo internal > "$TELMI_CONTENT_MODE_FILE"
			log_telmi "content=internal dev=$_dev (label)"
			return 0
		fi
	fi

	return 1
}

rescan_empty_mmc_hosts() {
	for _h in /sys/class/mmc_host/mmc*; do
		[ -d "$_h" ] || continue
		_need=0
		_hn=$(basename "$_h")
		_has_block=0
		for _c in "$_h"/mmc*/block/mmcblk*; do
			[ -e "$_c" ] && _has_block=1 && break
		done
		if [ "$_has_block" -eq 0 ]; then
			_need=1
		else
			# Carte vue par le host mais sans bloc (partition table pas lue)
			for _card in "$_h"/mmc*:*; do
				[ -d "$_card" ] || continue
				if [ ! -d "$_card/block" ] || [ -z "$(ls -A "$_card/block" 2>/dev/null)" ]; then
					_need=1
					break
				fi
			done
		fi
		[ "$_need" -eq 1 ] || continue
		if [ -w "$_h/rescan" ]; then
			log_telmi "rescan $_hn"
			echo 1 > "$_h/rescan" 2>/dev/null || true
		fi
	done
	# Declencher mdev si disponible (carte detectee mais pas de /dev/mmcblk*)
	if command -v mdev >/dev/null 2>&1; then
		mdev -s 2>/dev/null || true
	fi
}

mount_telmi_content() {
	ensure_sdcard_link
	mkdir -p /telmi
	if mountpoint -q /telmi 2>/dev/null; then
		return 0
	fi
	umount /telmi/.tmp_update 2>/dev/null || true
	umount /telmi 2>/dev/null || true

	# Attente : 8s V20, 20s V30 (slot gauche parfois lent). TELMI_WAIT_MAX force la valeur.
	_max=$(default_wait_max)

	log_mmc_inventory
	rescan_empty_mmc_hosts

	_i=0
	while [ "$_i" -lt "$_max" ]; do
		if mount_external_content; then
			return 0
		fi
		if mount_internal_content; then
			return 0
		fi
		# Re-inventaire si un nouveau mmcblk apparait
		_os=$(get_os_mmc_base) || _os=""
		for _cand in mmcblk0 mmcblk2 mmcblk3; do
			[ -d "/sys/block/$_cand" ] || continue
			[ "$_cand" = "$_os" ] && continue
			log_telmi "nouveau $_cand detecte"
			log_mmc_inventory
			if mount_external_content; then
				return 0
			fi
		done
		if [ $((_i % 3)) -eq 2 ]; then
			rescan_empty_mmc_hosts
		fi
		sleep 1
		_i=$((_i + 1))
	done

	log_mmc_inventory
	rm -f "$TELMI_CONTENT_MODE_FILE"
	log_telmi "content=missing (waited ${_max}s)"
	return 1
}

setup_tmp_update() {
	mkdir -p /telmi/.tmp_update
	umount /telmi/.tmp_update 2>/dev/null || true
	mount --bind /opt/telmi /telmi/.tmp_update 2>/dev/null || true
}

seed_content_tree() {
	mkdir -p /telmi/Stories /telmi/Music /telmi/Saves/Stories /telmi/logs \
		/telmi/Games/gb /telmi/Games/gbc /telmi/Games/gba \
		/telmi/Games/nes /telmi/Games/md /telmi/Games/snes /telmi/Games/psx
	if [ ! -f /telmi/Saves/.parameters ]; then
		cat > /telmi/Saves/.parameters <<'EOF'
{"audioVolumeStartup":0.5,"audioVolumeMax":1.0,"screenBrightnessStartup":0.4,"screenBrightnessMax":0.8,"screenOnInactivityTime":60,"screenOffInactivityTime":120,"musicInactivityTime":1800,"storyDisplayTiles":true,"storyDisableNightMode":false,"storyDisableTimeline":false,"musicDisableRepeatModes":false,"bootSplashscreen":""}
EOF
	fi
	if [ ! -f /telmi/autorun.inf ]; then
		cat > /telmi/autorun.inf <<'EOF'
[autorun]
icon  = .tmp_update/res/sdcard.ico
label = TelmiOS-v1.10.3
EOF
	fi
}

setup_content_full() {
	if ! mountpoint -q /telmi 2>/dev/null; then
		return 1
	fi
	seed_content_tree
	setup_tmp_update
	ensure_sdcard_link
	_n=$(find /telmi/Stories -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
	log_telmi "Stories dirs=$_n under /telmi/Stories"
	return 0
}

print_status() {
	if mountpoint -q /telmi 2>/dev/null; then
		_src=$(findmnt -n -o SOURCE /telmi 2>/dev/null || awk '$2=="/telmi"{print $1;exit}' /proc/mounts)
		_mode=$(cat "$TELMI_CONTENT_MODE_FILE" 2>/dev/null || echo unknown)
		echo "mounted $_src mode=$_mode"
	else
		echo "not mounted"
	fi
}

case "$1" in
	mount)
		mount_telmi_content
		;;
	setup)
		mount_telmi_content && setup_content_full
		;;
	status)
		print_status
		;;
	*)
		echo "Usage: $0 mount|setup|status" >&2
		exit 1
		;;
esac
