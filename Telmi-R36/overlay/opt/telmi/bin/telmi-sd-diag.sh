#!/bin/sh
# TelmiOS V30 — diagnostic SD dual-slot (un seul boot)
# Declenche si /boot/TELMI-SD-DIAG present et REV=v30*
# Log : /boot/telmi-sd-diag.log + /boot/telmi-sd-diag-VERDICT.txt
# Couleurs fb : phase en cours

set -eu

LOG=/boot/telmi-sd-diag.log
VERDICT=/boot/telmi-sd-diag-VERDICT.txt
FBCOLOR=/opt/telmi/bin/fbcolor
DT=/sys/firmware/devicetree/base
[ -d "$DT" ] || DT=/proc/device-tree

HOSTS_WITH_CARD=""
LEFT_HOST=""
LEFT_CARDS=0
GPIO_LEVELS=""
GPIO_PULSE=""
DMESG_HINTS=""
MOUNT_OK=""
RECOMMEND=""

log() {
	_ts="$(date '+%H:%M:%S' 2>/dev/null || echo '?')"
	echo "[sd-diag $_ts] $*" | tee -a "$LOG" 2>/dev/null || echo "[sd-diag $_ts] $*"
}

fb() {
	# r g b
	if [ -x "$FBCOLOR" ]; then
		"$FBCOLOR" "$1" "$2" "$3" >/dev/null 2>&1 || true
	fi
}

get_os_mmc() {
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
	echo ""
	return 1
}

hexdump_prop() {
	_f="$1"
	[ -f "$_f" ] || { echo "(absent)"; return 1; }
	# hex + printable
	od -An -tx1 "$_f" 2>/dev/null | tr -s ' ' | head -c 200
	echo
	# string if printable
	tr -d '\0' < "$_f" 2>/dev/null | head -c 80
	echo
}

phase_a_inventory() {
	fb 0 180 0
	log "=== PHASE A : inventaire MMC ==="
	_os=$(get_os_mmc) || _os="?"
	log "root_os_mmc=${_os}"
	log "TELMI-REV=$(tr -d '\r\n ' < /boot/TELMI-REV.txt 2>/dev/null || echo ?)"
	log "image=$(cat /opt/telmi/telmiVersion/image-version.txt 2>/dev/null || echo ?)"
	log "build=$(cat /opt/telmi/telmiVersion/build-id.txt 2>/dev/null || echo ?)"
	log "uname=$(uname -a 2>/dev/null || true)"

	HOSTS_WITH_CARD=""
	LEFT_HOST=""
	LEFT_CARDS=0

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
					_bn=$(basename "$_b")
					_blk="$_blk blk=$_bn"
					HOSTS_WITH_CARD="$HOSTS_WITH_CARD $_hn:$_bn"
					# mmc2 = slot gauche typique (alias)
					if [ "$_hn" = "mmc2" ] || [ "$_bn" != "$_os" ]; then
						:
					fi
					if [ "$_hn" = "mmc2" ]; then
						LEFT_HOST=mmc2
						LEFT_CARDS=$_cards
					fi
				done
			fi
			_detail="$_detail ${_cid}(type=${_type}${_blk})"
		done
		log "  host ${_hn}: cards=${_cards} blocks=${_blocks}${_detail}"
		# Heuristique left: host non-OS avec 0 cards → candidat gauche
		if [ "$_cards" -eq 0 ] && [ "$_hn" = "mmc2" ]; then
			LEFT_HOST=mmc2
			LEFT_CARDS=0
		fi
	done

	for _sys in /sys/block/mmcblk0 /sys/block/mmcblk1 /sys/block/mmcblk2 /sys/block/mmcblk3; do
		[ -d "$_sys" ] || continue
		_mmc=$(basename "$_sys")
		_note="candidate"
		[ "$_mmc" = "$_os" ] && _note="OS"
		_parts=""
		for _p in /dev/${_mmc}p1 /dev/${_mmc}p2 /dev/${_mmc}p3 /dev/${_mmc}p4; do
			[ -b "$_p" ] || continue
			_bl=$(blkid "$_p" 2>/dev/null | tr '\n' ' ' || true)
			_parts="$_parts $(basename "$_p"){${_bl:-no-blkid}}"
		done
		log "  ${_mmc} (${_note})${_parts}"
	done

	log "blkid (all):"
	blkid 2>/dev/null | while read -r _l; do log "  $_l"; done || log "  (blkid vide)"
}

phase_b_dtb() {
	fb 0 80 220
	log "=== PHASE B : device-tree dwmmc ==="
	if [ ! -d "$DT" ]; then
		log "ERREUR: pas de $DT"
		return 0
	fi
	for _alias in mmc0 mmc1 mmc2; do
		_af="$DT/aliases/$_alias"
		if [ -f "$_af" ]; then
			_av=$(tr -d '\0' < "$_af" 2>/dev/null || true)
			log "  alias $_alias -> $_av"
		fi
	done
	for _addr in ff370000 ff380000 ff390000; do
		_node="$DT/dwmmc@${_addr}"
		log "--- dwmmc@${_addr} ---"
		if [ ! -d "$_node" ]; then
			log "  (noeud absent)"
			continue
		fi
		for _prop in status broken-cd bus-width max-frequency cap-sd-highspeed supports-sd; do
			if [ -e "$_node/$_prop" ]; then
				_val=$(tr -d '\0' < "$_node/$_prop" 2>/dev/null || true)
				[ -n "$_val" ] || _val="(empty/flag)"
				log "  $_prop=$_val"
			fi
		done
		for _prop in cd-gpios vmmc-supply vqmmc-supply pinctrl-0 pinctrl-names; do
			if [ -e "$_node/$_prop" ]; then
				log "  $_prop hex:"
				hexdump_prop "$_node/$_prop" | while read -r _l; do log "    $_l"; done
			else
				log "  $_prop=(absent)"
			fi
		done
	done
}

gpio_chip_for_label() {
	# Prefer label match; fallback order gpio0/gpio3 by name
	_want="$1"
	for _c in /sys/class/gpio/gpiochip*; do
		[ -e "$_c" ] || continue
		_lab=$(cat "$_c/label" 2>/dev/null || true)
		case "$_lab" in
			*"$_want"*|$_want) echo "$_c"; return 0 ;;
		esac
	done
	# rockchip often labels ff040000.gpio / gpio0
	for _c in /sys/class/gpio/gpiochip*; do
		[ -e "$_c" ] || continue
		_lab=$(cat "$_c/label" 2>/dev/null || true)
		case "$_lab" in
			*ff040000*|*gpio0*) [ "$_want" = "gpio0" ] && { echo "$_c"; return 0; } ;;
			*ff270000*|*gpio3*) [ "$_want" = "gpio3" ] && { echo "$_c"; return 0; } ;;
		esac
	done
	return 1
}

gpio_read_one() {
	_name="$1"   # e.g. gpio0.2
	_bank="$2"   # gpio0
	_pin="$3"
	_chip=$(gpio_chip_for_label "$_bank") || {
		log "  $_name: chip $_bank introuvable"
		GPIO_LEVELS="$GPIO_LEVELS ${_name}=NOCHIP"
		return 1
	}
	_base=$(cat "$_chip/base" 2>/dev/null || echo "")
	_ngpio=$(cat "$_chip/ngpio" 2>/dev/null || echo "")
	_lab=$(cat "$_chip/label" 2>/dev/null || echo "")
	log "  chip $_bank: path=$_chip base=$_base ngpio=$_ngpio label=$_lab"
	_n=$((_base + _pin))
	if [ -d "/sys/class/gpio/gpio${_n}" ]; then
		_val=$(cat "/sys/class/gpio/gpio${_n}/value" 2>/dev/null || echo ERR)
		log "  $_name: already exported gpio${_n} value=$_val"
		GPIO_LEVELS="$GPIO_LEVELS ${_name}=$_val"
		return 0
	fi
	if echo "$_n" > /sys/class/gpio/export 2>/tmp/sd-diag-gpio.err; then
		echo in > "/sys/class/gpio/gpio${_n}/direction" 2>/dev/null || true
		_val=$(cat "/sys/class/gpio/gpio${_n}/value" 2>/dev/null || echo ERR)
		log "  $_name: exported gpio${_n} value=$_val"
		GPIO_LEVELS="$GPIO_LEVELS ${_name}=$_val"
		echo "$_n" > /sys/class/gpio/unexport 2>/dev/null || true
		return 0
	fi
	_err=$(tr '\n' ' ' < /tmp/sd-diag-gpio.err 2>/dev/null || true)
	log "  $_name: export gpio${_n} FAIL ($_err) — conflit possible"
	GPIO_LEVELS="$GPIO_LEVELS ${_name}=BUSY"
	return 1
}

phase_c_gpio() {
	fb 220 180 0
	log "=== PHASE C : GPIO CD candidats ==="
	GPIO_LEVELS=""
	for _c in /sys/class/gpio/gpiochip*; do
		[ -e "$_c" ] || continue
		log "  gpiochip $(basename "$_c") base=$(cat "$_c/base" 2>/dev/null) ngpio=$(cat "$_c/ngpio" 2>/dev/null) label=$(cat "$_c/label" 2>/dev/null)"
	done
	# V20 clone CD right=gpio0.3 left=gpio0.2 ; V30 ArkOS left=gpio3.14
	gpio_read_one "gpio0.2" gpio0 2 || true
	gpio_read_one "gpio0.3" gpio0 3 || true
	gpio_read_one "gpio3.14" gpio3 14 || true
	log "GPIO_LEVELS=$GPIO_LEVELS"
}

phase_d_regulators() {
	fb 180 0 180
	log "=== PHASE D : regulateurs ==="
	for _r in /sys/class/regulator/regulator.*; do
		[ -d "$_r" ] || continue
		_name=$(cat "$_r/name" 2>/dev/null || echo ?)
		case "$_name" in
			*sd*|*SD*|*dvp*|*lcd*|*LCD*|*vcc*|*VCC*)
				_st=$(cat "$_r/state" 2>/dev/null || echo ?)
				_uv=$(cat "$_r/microvolts" 2>/dev/null || echo ?)
				log "  $_name state=$_st uV=$_uv path=$(basename "$_r")"
				;;
		esac
	done
}

rescan_empty() {
	for _h in /sys/class/mmc_host/mmc*; do
		[ -d "$_h" ] || continue
		_has=0
		for _c in "$_h"/mmc*/block/mmcblk*; do
			[ -e "$_c" ] && _has=1 && break
		done
		[ "$_has" -eq 1 ] && continue
		if [ -w "$_h/rescan" ]; then
			log "  rescan $(basename "$_h")"
			echo 1 > "$_h/rescan" 2>/dev/null || true
		fi
	done
	command -v mdev >/dev/null 2>&1 && mdev -s 2>/dev/null || true
}

gpio_pulse_one() {
	_name="$1"
	_bank="$2"
	_pin="$3"
	_chip=$(gpio_chip_for_label "$_bank") || {
		log "  pulse $_name: no chip"
		GPIO_PULSE="$GPIO_PULSE ${_name}=NOCHIP"
		return 1
	}
	_base=$(cat "$_chip/base")
	_n=$((_base + _pin))
	if ! echo "$_n" > /sys/class/gpio/export 2>/tmp/sd-diag-gpio.err; then
		_err=$(tr '\n' ' ' < /tmp/sd-diag-gpio.err 2>/dev/null || true)
		log "  pulse $_name: export FAIL ($_err)"
		GPIO_PULSE="$GPIO_PULSE ${_name}=BUSY"
		return 1
	fi
	echo out > "/sys/class/gpio/gpio${_n}/direction" 2>/dev/null || true
	echo 0 > "/sys/class/gpio/gpio${_n}/value" 2>/dev/null || true
	sleep 1
	rescan_empty
	_appeared=0
	[ -d /sys/block/mmcblk2 ] && _appeared=1
	echo 1 > "/sys/class/gpio/gpio${_n}/value" 2>/dev/null || true
	sleep 1
	rescan_empty
	[ -d /sys/block/mmcblk2 ] && _appeared=1
	# aussi mmcblk0 non-OS
	_os=$(get_os_mmc) || _os=""
	if [ -d /sys/block/mmcblk0 ] && [ "$_os" != "mmcblk0" ]; then
		_appeared=1
	fi
	echo in > "/sys/class/gpio/gpio${_n}/direction" 2>/dev/null || true
	echo "$_n" > /sys/class/gpio/unexport 2>/dev/null || true
	log "  pulse $_name: appeared_extra=${_appeared}"
	GPIO_PULSE="$GPIO_PULSE ${_name}=appeared${_appeared}"
}

phase_e_rescan() {
	fb 220 80 0
	log "=== PHASE E : dmesg MMC + rescan + pulse GPIO ==="
	DMESG_HINTS=""
	if command -v dmesg >/dev/null 2>&1; then
		dmesg 2>/dev/null | grep -iE 'mmc|dwmmc|sdhci|sdio' | tail -n 80 | while read -r _l; do
			log "  dmesg: $_l"
		done
		_errc=$(dmesg 2>/dev/null | grep -icE 'mmc.*(error|timeout|fail|ocr|no card)' || true)
		DMESG_HINTS="mmc_err_lines≈${_errc}"
		log "  $DMESG_HINTS"
	else
		log "  dmesg absent"
	fi

	GPIO_PULSE=""
	_i=0
	while [ "$_i" -lt 10 ]; do
		rescan_empty
		if [ -d /sys/block/mmcblk2 ] || { [ -d /sys/block/mmcblk0 ] && [ "$(get_os_mmc)" != "mmcblk0" ]; }; then
			log "  nouveau bloc detecte pendant rescan (i=$_i)"
			phase_a_inventory
			break
		fi
		sleep 1
		_i=$((_i + 1))
	done

	log "--- pulses GPIO CD (experience a chaud) ---"
	gpio_pulse_one "gpio0.2" gpio0 2 || true
	gpio_pulse_one "gpio3.14" gpio3 14 || true
	log "GPIO_PULSE=$GPIO_PULSE"
	phase_a_inventory
}

phase_f_mount() {
	fb 0 200 200
	log "=== PHASE F : tentatives mount non-OS ==="
	MOUNT_OK=""
	_os=$(get_os_mmc) || _os=""
	mkdir -p /mnt

	for _mmc in mmcblk0 mmcblk1 mmcblk2 mmcblk3; do
		[ -d "/sys/block/$_mmc" ] || continue
		[ "$_mmc" = "$_os" ] && continue
		for _p in "${_mmc}" "${_mmc}p1" "${_mmc}p2" "${_mmc}p3"; do
			_dev="/dev/$_p"
			[ -b "$_dev" ] || continue
			_mp="/mnt/telmi-diag-$_p"
			mkdir -p "$_mp"
			umount "$_mp" 2>/dev/null || true
			if mount -t vfat "$_dev" "$_mp" 2>/tmp/sd-diag-mnt.err; then
				_nst=$(find "$_mp/Stories" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
				_lbl=$(blkid "$_dev" 2>/dev/null | tr '\n' ' ' || true)
				log "  MOUNT OK $_dev -> $_mp Stories=$_nst blkid=$_lbl"
				MOUNT_OK="$MOUNT_OK $_dev"
				umount "$_mp" 2>/dev/null || true
			elif mount -t msdos "$_dev" "$_mp" 2>/tmp/sd-diag-mnt.err; then
				log "  MOUNT OK (msdos) $_dev"
				MOUNT_OK="$MOUNT_OK $_dev"
				umount "$_mp" 2>/dev/null || true
			else
				_err=$(tr '\n' ' ' < /tmp/sd-diag-mnt.err 2>/dev/null || true)
				log "  mount FAIL $_dev ($_err)"
			fi
		done
	done
	[ -z "$MOUNT_OK" ] && log "  (aucun montage non-OS — attendu si mmc2 cards=0)"
}

phase_g_verdict() {
	fb 255 255 255
	log "=== PHASE G : VERDICT ==="
	_os=$(get_os_mmc) || _os="?"
	# recount left
	if [ -d /sys/class/mmc_host/mmc2 ]; then
		LEFT_HOST=mmc2
		LEFT_CARDS=0
		for _c in /sys/class/mmc_host/mmc2/mmc*/block/mmcblk*; do
			[ -e "$_c" ] && LEFT_CARDS=1 && break
		done
	fi

	if [ -n "$MOUNT_OK" ]; then
		RECOMMEND="carte_vue_et_montee — dual-SD OK cote kernel; verifier Stories/"
	elif [ "$LEFT_CARDS" -gt 0 ]; then
		RECOMMEND="carte_vue_mais_mount_fail — FS/label/options mount"
	elif echo "$GPIO_LEVELS" | grep -q 'BUSY'; then
		RECOMMEND="gpio_cd_en_conflit — verifier wifi/chip_en vs cd-gpios DTB"
	elif echo "$GPIO_PULSE" | grep -q 'appeared1'; then
		RECOMMEND="pulse_gpio_a_reveille_slot — ajuster cd-gpios DTB vers ce pin"
	elif [ "$LEFT_CARDS" -eq 0 ]; then
		RECOMMEND="bus_gauche_mort — alim/pinctrl/vqmmc ou slot HW; dmesg+regulateurs ci-dessus"
	else
		RECOMMEND="indetermine — envoyer log complet"
	fi

	{
		echo "Telmi SD-DIAG VERDICT"
		echo "date=$(date 2>/dev/null || true)"
		echo "image=$(cat /opt/telmi/telmiVersion/image-version.txt 2>/dev/null || echo ?)"
		echo "build=$(cat /opt/telmi/telmiVersion/build-id.txt 2>/dev/null || echo ?)"
		echo "rev=$(tr -d '\r\n ' < /boot/TELMI-REV.txt 2>/dev/null || echo ?)"
		echo "baseline=mmc1_only_expected_if_left_dead"
		echo "root_os_mmc=$_os"
		echo "hosts_with_card=$HOSTS_WITH_CARD"
		echo "left_slot_host=${LEFT_HOST:-?} cards=${LEFT_CARDS}"
		echo "cd_gpio_levels=$GPIO_LEVELS"
		echo "gpio_pulse_result=$GPIO_PULSE"
		echo "dmesg_mmc=$DMESG_HINTS"
		echo "mount_ok=$MOUNT_OK"
		echo "recommend=$RECOMMEND"
		echo "full_log=telmi-sd-diag.log"
	} | tee "$VERDICT" | while read -r _l; do log "VERDICT: $_l"; done

	log "Diag termine. Extinction."
	fb 40 40 40
}

main() {
	mkdir -p /boot
	mountpoint -q /boot 2>/dev/null || mount /boot 2>/dev/null || true
	: >"$LOG" 2>/dev/null || {
		echo "ERREUR: impossible d'ecrire $LOG" >&2
		exit 1
	}
	log "=== Telmi SD-DIAG start ==="
	[ -c /dev/fb0 ] && echo 0 > /sys/class/graphics/fb0/blank 2>/dev/null || true

	phase_a_inventory
	phase_b_dtb
	phase_c_gpio
	phase_d_regulators
	phase_e_rescan
	phase_f_mount
	phase_g_verdict
	sync
	sleep 2
}

main "$@"
