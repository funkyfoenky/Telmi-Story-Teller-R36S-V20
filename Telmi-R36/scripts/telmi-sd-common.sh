# Bibliotheque partagee Linux / macOS (bash 3.2+).
# Sourcee par flash-telmi-sd.sh, prepare-content-sd.sh, select-telmi-rev.sh.
#
# PATH brew (Apple Silicon + Intel) avant sudo secure_path.

# shellcheck disable=SC2034
TELMI_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TELMI_R36="$(cd "$TELMI_COMMON_DIR/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$TELMI_R36/output}"
CONTENT_DIR="${CONTENT_DIR:-$TELMI_R36/content}"

export PATH="/opt/homebrew/sbin:/opt/homebrew/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export LC_ALL=C

TELMI_UNAME="$(uname -s)"
case "$TELMI_UNAME" in
	Linux)  TELMI_OS="linux" ;;
	Darwin) TELMI_OS="macos" ;;
	*)
		echo "ERREUR : OS non supporté ($TELMI_UNAME). Linux ou macOS requis."
		exit 1
		;;
esac

telmi_need_root() {
	if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
		echo "==> Élévation root (sudo)..."
		exec sudo env PATH="$PATH" bash "$0" "$@"
	fi
}

telmi_file_size() {
	if stat -c%s "$1" >/dev/null 2>&1; then
		stat -c%s "$1"
	else
		stat -f%z "$1"
	fi
}

telmi_fmt_gb() {
	awk -v b="$1" 'BEGIN { printf "%.1f Go", b/1024/1024/1024 }'
}

# $1 = ligne lsblk -P, $2 = clé
_telmi_kv() {
	printf '%s\n' "$1" | sed -n "s/.*${2}=\"\\([^\"]*\\)\".*/\\1/p"
}

telmi_is_system_disk() {
	local dev="$1"
	local root_src parent
	if [[ "$TELMI_OS" = "macos" ]]; then
		[[ "$dev" = "/dev/disk0" ]] && return 0
		return 1
	fi
	root_src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
	[[ -z "$root_src" ]] && return 1
	parent="$(lsblk -npo PKNAME "$root_src" 2>/dev/null || true)"
	if [[ -n "$parent" && "/dev/$parent" = "$dev" ]]; then
		return 0
	fi
	case "$root_src" in
		"$dev"|"$dev"p*|"$dev"[0-9]*) return 0 ;;
	esac
	return 1
}

# Remplit les tableaux globaux TELMI_DEV_LIST / TELMI_SIZE_LIST / TELMI_LABEL_LIST (index 1..N)
TELMI_DEV_LIST=()
TELMI_SIZE_LIST=()
TELMI_LABEL_LIST=()
TELMI_DISK_COUNT=0

telmi_list_removable() {
	TELMI_DEV_LIST=()
	TELMI_SIZE_LIST=()
	TELMI_LABEL_LIST=()
	TELMI_DISK_COUNT=0
	if [[ "$TELMI_OS" = "macos" ]]; then
		_telmi_list_removable_macos
	else
		_telmi_list_removable_linux
	fi
}

_telmi_list_removable_linux() {
	local line name size type tran model rm n
	n=0
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		name="$(_telmi_kv "$line" NAME)"
		size="$(_telmi_kv "$line" SIZE)"
		type="$(_telmi_kv "$line" TYPE)"
		tran="$(_telmi_kv "$line" TRAN)"
		model="$(_telmi_kv "$line" MODEL)"
		rm="$(_telmi_kv "$line" RM)"
		[[ "$type" = "disk" ]] || continue
		[[ -n "$name" && -n "$size" ]] || continue
		[[ "$size" -ge $((3 * 1024 * 1024 * 1024)) ]] || continue
		[[ "$size" -le $((2 * 1024 * 1024 * 1024 * 1024)) ]] || continue
		telmi_is_system_disk "$name" && continue
		case "$tran" in
			usb|mmc|sd|spi) ;;
			*)
				[[ "$rm" = "1" ]] || continue
				;;
		esac
		n=$((n + 1))
		TELMI_DEV_LIST[$n]="$name"
		TELMI_SIZE_LIST[$n]="$size"
		TELMI_LABEL_LIST[$n]="${model:-$tran} ($tran)"
	done < <(lsblk -dnp -b -P -o NAME,SIZE,TYPE,TRAN,MODEL,RM 2>/dev/null)
	TELMI_DISK_COUNT=$n
}

_telmi_list_removable_macos() {
	local d ident bytes name proto n info
	n=0
	for ident in $(diskutil list external physical 2>/dev/null | awk '/^\/dev\/disk[0-9]+/ { print $1 }'); do
		[[ -n "$ident" ]] || continue
		d="$ident"
		case "$d" in
			/dev/*) ;;
			*) d="/dev/$d" ;;
		esac
		info="$(diskutil info "$d" 2>/dev/null)" || continue
		echo "$info" | grep -q 'Whole: *Yes' || continue
		bytes="$(echo "$info" | awk -F '[()]' '/Disk Size/ { gsub(/ Bytes/,"",$2); gsub(/ /,"",$2); print $2; exit }')"
		[[ -n "$bytes" && "$bytes" -ge $((3 * 1024 * 1024 * 1024)) ]] || continue
		[[ "$bytes" -le $((2 * 1024 * 1024 * 1024 * 1024)) ]] || continue
		name="$(echo "$info" | awk -F ': *' '/Media Name:/ { print $2; exit }')"
		[[ -n "$name" ]] || name="$(echo "$info" | awk -F ': *' '/Device Node:/ { print $2; exit }')"
		proto="$(echo "$info" | awk -F ': *' '/^ *Protocol:/ { print $2; exit }')"
		n=$((n + 1))
		TELMI_DEV_LIST[$n]="$d"
		TELMI_SIZE_LIST[$n]="$bytes"
		TELMI_LABEL_LIST[$n]="${name:-disk} (${proto:-USB})"
	done
	TELMI_DISK_COUNT=$n
}

telmi_print_disks() {
	local i
	if [[ "$TELMI_DISK_COUNT" -eq 0 ]]; then
		echo "Aucun disque USB/SD amovible (>= 3 Go)."
		if [[ "$TELMI_OS" = "macos" ]]; then
			diskutil list
		else
			lsblk -o NAME,SIZE,TYPE,TRAN,MODEL,MOUNTPOINTS
		fi
		return 1
	fi
	echo " Disques amovibles :"
	i=1
	while [[ $i -le $TELMI_DISK_COUNT ]]; do
		echo "  [$i] ${TELMI_DEV_LIST[$i]}  $(telmi_fmt_gb "${TELMI_SIZE_LIST[$i]}")  ${TELMI_LABEL_LIST[$i]}"
		i=$((i + 1))
	done
}

telmi_normalize_dev() {
	local d="$1"
	if [[ "$TELMI_OS" = "macos" ]]; then
		d="${d#/dev/}"
		case "$d" in
			rdisk*) d="disk${d#rdisk}" ;;
		esac
		echo "/dev/$d"
	else
		case "$d" in
			/dev/*) echo "$d" ;;
			*) echo "/dev/$d" ;;
		esac
	fi
}

telmi_raw_dev() {
	if [[ "$TELMI_OS" = "macos" ]]; then
		echo "/dev/r${DEV#/dev/}"
	else
		echo "$DEV"
	fi
}

telmi_dev_exists() {
	[[ -e "$1" ]]
}

telmi_assert_whole_disk() {
	local t
	if [[ "$TELMI_OS" = "macos" ]]; then
		if ! diskutil info "$DEV" 2>/dev/null | grep -q 'Whole: *Yes'; then
			echo "ERREUR : $DEV n'est pas un disque entier (utilisez diskN, pas diskNs1)."
			exit 1
		fi
		return 0
	fi
	t="$(lsblk -dno TYPE "$DEV" 2>/dev/null || true)"
	if [[ -n "$t" && "$t" != "disk" ]]; then
		echo "ERREUR : $DEV n'est pas un disque entier (ex. /dev/sdb, pas /dev/sdb1)."
		exit 1
	fi
}

telmi_disk_bytes() {
	if [[ "$TELMI_OS" = "macos" ]]; then
		diskutil info "$1" | awk -F '[()]' '/Disk Size/ { gsub(/ Bytes/,"",$2); gsub(/ /,"",$2); print $2; exit }'
	else
		blockdev --getsize64 "$1"
	fi
}

# Partition n : /dev/sdb3, /dev/mmcblk0p3, /dev/disk4s3
part_path() {
	local n="$1"
	if [[ "$TELMI_OS" = "macos" ]]; then
		echo "${DEV}s${n}"
	elif [[ "$DEV" =~ [0-9]$ ]]; then
		echo "${DEV}p${n}"
	else
		echo "${DEV}${n}"
	fi
}

telmi_umount_all() {
	local p
	echo "==> Démontage de $DEV..."
	if [[ "$TELMI_OS" = "macos" ]]; then
		diskutil unmountDisk force "$DEV" >/dev/null 2>&1 || true
		return 0
	fi
	if command -v lsblk >/dev/null 2>&1; then
		for p in $(lsblk -nrpo NAME "$DEV" 2>/dev/null | tail -n +2); do
			umount "$p" 2>/dev/null || umount -l "$p" 2>/dev/null || true
		done
	fi
	umount "$DEV" 2>/dev/null || true
}

telmi_umount_part() {
	local part="$1"
	if [[ "$TELMI_OS" = "macos" ]]; then
		diskutil unmount "$part" >/dev/null 2>&1 || umount "$part" 2>/dev/null || true
	else
		umount "$part" 2>/dev/null || umount -l "$part" 2>/dev/null || true
	fi
}

telmi_reread_pt() {
	sync
	if [[ "$TELMI_OS" = "macos" ]]; then
		diskutil unmountDisk force "$DEV" >/dev/null 2>&1 || true
		sleep 1
	else
		partprobe "$DEV" 2>/dev/null || true
		blockdev --rereadpt "$DEV" 2>/dev/null || true
		command -v udevadm >/dev/null 2>&1 && udevadm settle 2>/dev/null || true
		sleep 1
	fi
}

wait_parts() {
	local need="${1:-3}"
	local i p ok
	telmi_reread_pt
	i=1
	while [[ $i -le 20 ]]; do
		ok=1
		p=1
		while [[ $p -le $need ]]; do
			if [[ ! -e "$(part_path "$p")" ]]; then
				ok=0
				break
			fi
			p=$((p + 1))
		done
		[[ $ok -eq 1 ]] && return 0
		sleep 0.5
		telmi_reread_pt
		i=$((i + 1))
	done
	echo "ERREUR : partitions introuvables après partitionnement"
	if [[ "$TELMI_OS" = "macos" ]]; then
		diskutil list "$DEV"
	else
		lsblk "$DEV"
	fi
	return 1
}

telmi_need_sgdisk() {
	if command -v sgdisk >/dev/null 2>&1; then
		return 0
	fi
	echo "ERREUR : sgdisk (gdisk / gptfdisk) est requis pour GPT (sgdisk -e)."
	if [[ "$TELMI_OS" = "macos" ]]; then
		echo "         brew install gptfdisk"
		echo "         (sous sudo, le PATH Homebrew est déjà injecté)"
	else
		echo "         Debian/Ubuntu : sudo apt install gdisk"
		echo "         Fedora        : sudo dnf install gdisk"
		echo "         Arch          : sudo pacman -S gptfdisk"
	fi
	exit 1
}

telmi_need_fat32() {
	if [[ "$TELMI_OS" = "macos" ]]; then
		command -v newfs_msdos >/dev/null 2>&1 && return 0
		echo "ERREUR : newfs_msdos introuvable"
		exit 1
	fi
	if command -v mkfs.vfat >/dev/null 2>&1 || command -v mkfs.fat >/dev/null 2>&1; then
		return 0
	fi
	echo "ERREUR : mkfs.vfat / mkfs.fat requis (dosfstools)."
	echo "         Debian/Ubuntu : sudo apt install dosfstools"
	echo "         Fedora        : sudo dnf install dosfstools"
	exit 1
}

telmi_format_fat32() {
	local part="$1"
	local label="${2:-TELMI}"
	telmi_umount_part "$part"
	sleep 0.3
	if [[ "$TELMI_OS" = "macos" ]]; then
		newfs_msdos -F 32 -v "$label" "$part"
	elif command -v mkfs.vfat >/dev/null 2>&1; then
		mkfs.vfat -F 32 -n "$label" "$part"
	else
		mkfs.fat -F 32 -n "$label" "$part"
	fi
}

telmi_mount_fat() {
	local part="$1"
	local mnt="$2"
	mkdir -p "$mnt"
	telmi_umount_part "$part"
	if [[ "$TELMI_OS" = "macos" ]]; then
		if diskutil mount -mountPoint "$mnt" "$part" >/dev/null 2>&1; then
			return 0
		fi
		mount -t msdos "$part" "$mnt"
	else
		mount "$part" "$mnt"
	fi
}

telmi_write_image() {
	local img="$1"
	local dest raw bs_arg img_bytes
	img_bytes="$(telmi_file_size "$img")"
	dest="$(telmi_raw_dev)"
	if [[ "$TELMI_OS" = "macos" ]]; then
		bs_arg="4m"
	else
		bs_arg="4M"
	fi
	echo "==> Écriture $(basename "$img") -> $dest ..."
	telmi_umount_all
	sleep 0.5
	if command -v pv >/dev/null 2>&1; then
		pv -s "$img_bytes" "$img" | dd of="$dest" bs="$bs_arg"
	elif dd if=/dev/zero of=/dev/null bs=1 count=0 status=progress 2>/dev/null; then
		if [[ "$TELMI_OS" = "macos" ]]; then
			dd if="$img" of="$dest" bs="$bs_arg" status=progress
		else
			dd if="$img" of="$dest" bs="$bs_arg" conv=fsync,notrunc status=progress
		fi
	else
		echo "  (pas de barre de progression — patience, plusieurs minutes)"
		dd if="$img" of="$dest" bs="$bs_arg"
	fi
	sync
	echo "  Écriture image OK"
}

telmi_repair_gpt() {
	echo "==> Correction GPT secondaire (sgdisk -e)..."
	telmi_need_sgdisk
	sgdisk -e "$DEV" 2>/dev/null || sgdisk -e "$DEV"
	telmi_reread_pt
}

# Recrée p3 jusqu'à la fin du disque (après p2). N'attend pas le format.
telmi_recreate_p3() {
	local p2_end start
	telmi_need_sgdisk
	p2_end="$(sgdisk -i 2 "$DEV" 2>/dev/null | awk -F': *' '/Last sector/ { gsub(/ .*/,"",$2); print $2; exit }')"
	if [[ -z "${p2_end:-}" ]]; then
		echo "ERREUR : partition root (p2) introuvable — image incomplète ?"
		sgdisk -p "$DEV" || true
		exit 1
	fi
	start=$((p2_end + 1))
	# Alignement 1 MiB (2048 secteurs de 512)
	if [[ $((start % 2048)) -ne 0 ]]; then
		start=$(( (start / 2048 + 1) * 2048 ))
	fi
	echo "==> Recreation p3 TELMI (début secteur $start → fin du disque)..."
	sgdisk -d 5 "$DEV" 2>/dev/null || true
	sgdisk -d 4 "$DEV" 2>/dev/null || true
	sgdisk -d 3 "$DEV" 2>/dev/null || true
	sgdisk -n "3:${start}:0" -t 3:0700 -c 3:TELMI "$DEV"
	telmi_reread_pt
	wait_parts 3
}

telmi_copy_tree() {
	local src="$1"
	local dst="$2"
	if command -v rsync >/dev/null 2>&1; then
		rsync -rl --no-owner --no-group --no-perms \
			--exclude='.gitkeep' --exclude='.git' --exclude='.keep' \
			"$src/" "$dst/"
	else
		cp -R "$src/." "$dst/"
	fi
}

# $1=point de montage  $2=content-only (0/1)
seed_telmi_content_tree() {
	local mnt="$1"
	local content_only="${2:-0}"
	local d
	echo "==> Arborescence TELMI"
	mkdir -p "$CONTENT_DIR/Stories" "$CONTENT_DIR/Music" \
		"$CONTENT_DIR/Games" "$CONTENT_DIR/Saves/Stories" "$CONTENT_DIR/logs" \
		"$CONTENT_DIR/config" \
		"$CONTENT_DIR/Games/gb" "$CONTENT_DIR/Games/gbc" "$CONTENT_DIR/Games/gba" \
		"$CONTENT_DIR/Games/nes" "$CONTENT_DIR/Games/md" "$CONTENT_DIR/Games/snes" \
		"$CONTENT_DIR/Games/psx"
	for d in gb gbc gba nes md snes psx; do
		touch "$CONTENT_DIR/Games/$d/.keep"
	done
	for d in Stories Music Games Saves logs config \
		Games/gb Games/gbc Games/gba Games/nes Games/md Games/snes Games/psx \
		Saves/Stories; do
		mkdir -p "$mnt/$d"
	done
	if [[ -d "$CONTENT_DIR" ]]; then
		telmi_copy_tree "$CONTENT_DIR" "$mnt"
	fi
	for d in gb gbc gba nes md snes psx; do
		mkdir -p "$mnt/Games/$d"
		touch "$mnt/Games/$d/.keep"
	done
	if [[ -f "$TELMI_R36/assets/res/miyoo283_system.json" && ! -f "$mnt/system.json" ]]; then
		cp -f "$TELMI_R36/assets/res/miyoo283_system.json" "$mnt/system.json"
	fi
	if [[ ! -f "$mnt/autorun.inf" ]]; then
		printf '%s\n' '[autorun]' 'icon  = .tmp_update/res/sdcard.ico' 'label = TelmiOS-v1.10.3' > "$mnt/autorun.inf"
	fi
	if [[ "$content_only" = "1" ]]; then
		mkdir -p "$mnt/.tmp_update/res" "$mnt/.tmp_update/telmiVersion"
		if [[ -f "$TELMI_R36/assets/res/sdcard.ico" ]]; then
			cp -f "$TELMI_R36/assets/res/sdcard.ico" "$mnt/.tmp_update/res/sdcard.ico"
		fi
		printf '%s\n' 'R36S dual-SD content (slot gauche)' > "$mnt/.tmp_update/telmiVersion/content-only.txt"
		cat > "$mnt/README.txt" <<'EOF'
TelmiOS - carte CONTENU (slot gauche R36S)

Stories/  Music/  Games/  Saves/
Sync Telmi Sync sur PC avec cette carte.
OS Telmi sur la SD du slot droit uniquement.
EOF
	else
		cat > "$mnt/README.txt" <<'EOF'
TelmiOS — partition TELMI (FAT32)

Stories/<NomHistoire>/
Music/*.mp3
Games/
  gb/ gbc/ gba/ nes/ md/ snes/ psx/
Saves/          (BIOS PSX : scph5501.bin etc.)
system.json

Montée sur la console à /telmi (= /mnt/SDCARD).
Select x3 sur le carrousel = mode jeux.
EOF
	fi
	if [[ -f "$CONTENT_DIR/Games/README.txt" ]]; then
		mkdir -p "$mnt/Games"
		cp -f "$CONTENT_DIR/Games/README.txt" "$mnt/Games/README.txt"
	fi
	sync
}

seed_telmi_content() {
	local part="$1"
	local content_only="${2:-0}"
	local mnt
	mnt="$(mktemp -d /tmp/telmi-mnt-XXXXXX)"
	telmi_mount_fat "$part" "$mnt"
	seed_telmi_content_tree "$mnt" "$content_only"
	sync
	if [[ "$TELMI_OS" = "macos" ]]; then
		diskutil unmount "$mnt" >/dev/null 2>&1 || umount "$mnt" 2>/dev/null || true
	else
		umount "$mnt"
	fi
	rmdir "$mnt" 2>/dev/null || true
}

expand_telmi_partition() {
	telmi_need_fat32
	telmi_repair_gpt
	telmi_recreate_p3
	echo "==> Format TELMI FAT32..."
	telmi_format_fat32 "$(part_path 3)" TELMI
	seed_telmi_content "$(part_path 3)" 0
}

# Volume BOOT déjà monté contenant revs.json (un chemin par ligne)
telmi_find_boot_mounts() {
	local v
	if [[ "$TELMI_OS" = "macos" ]]; then
		for v in /Volumes/*; do
			[[ -f "$v/revs.json" ]] && printf '%s\n' "$v"
		done
		return 0
	fi
	for v in /media/* /media/*/* /run/media/*/* /mnt/* /mnt/*/*; do
		[[ -f "$v/revs.json" ]] && printf '%s\n' "$v"
	done
	if command -v lsblk >/dev/null 2>&1; then
		lsblk -pn -o LABEL,MOUNTPOINT 2>/dev/null | awk '$1=="BOOT" && $2!="" { print $2 }'
	fi
}

# Imprime le chemin du volume BOOT (revs.json) ; monte si besoin. Code retour 0.
telmi_resolve_boot_root() {
	local m p label_dev line name lbl
	m="$(telmi_find_boot_mounts | awk 'NF && !seen[$0]++ { print; exit }')"
	if [[ -n "$m" && -f "$m/revs.json" ]]; then
		printf '%s\n' "$m"
		return 0
	fi
	if [[ "$TELMI_OS" = "macos" ]]; then
		p="$(diskutil list | awk '/BOOT/ { print $NF; exit }')"
		if [[ -n "$p" ]]; then
			diskutil mount "$p" >/dev/null 2>&1 || true
			m="$(diskutil info "$p" 2>/dev/null | awk -F ': *' '/Mount Point:/ { print $2; exit }')"
			if [[ -n "$m" && "$m" != "Not applicable" && -f "$m/revs.json" ]]; then
				printf '%s\n' "$m"
				return 0
			fi
		fi
		return 1
	fi
	label_dev=""
	if [[ -e /dev/disk/by-label/BOOT ]]; then
		label_dev="$(readlink -f /dev/disk/by-label/BOOT 2>/dev/null || true)"
	fi
	if [[ -z "$label_dev" ]] && command -v blkid >/dev/null 2>&1; then
		label_dev="$(blkid -L BOOT 2>/dev/null || true)"
	fi
	if [[ -z "$label_dev" ]] && command -v lsblk >/dev/null 2>&1; then
		while IFS= read -r line; do
			name="$(_telmi_kv "$line" NAME)"
			lbl="$(_telmi_kv "$line" LABEL)"
			[[ "$lbl" = "BOOT" ]] || continue
			label_dev="$name"
			break
		done < <(lsblk -np -P -o NAME,LABEL)
	fi
	[[ -n "$label_dev" ]] || return 1
	m=""
	if command -v udisksctl >/dev/null 2>&1; then
		udisksctl mount -b "$label_dev" >/dev/null 2>&1 || true
		m="$(lsblk -npo MOUNTPOINT "$label_dev" 2>/dev/null | awk 'NF{print; exit}')"
	fi
	if [[ -z "$m" || ! -f "${m:-}/revs.json" ]]; then
		m="$(mktemp -d /tmp/telmi-boot-XXXXXX)"
		mount "$label_dev" "$m" 2>/dev/null || return 1
	fi
	[[ -f "$m/revs.json" ]] || return 1
	printf '%s\n' "$m"
}

resolve_latest_telmi_img() {
	local n latest f base
	if [[ -n "${WORKING_IMG:-}" && -f "$WORKING_IMG" ]]; then
		echo "$WORKING_IMG"
		return 0
	fi
	if [[ -f "$OUTPUT_DIR/LATEST.txt" ]]; then
		n="$(tr -d '[:space:]' < "$OUTPUT_DIR/LATEST.txt")"
		if [[ -n "$n" && -f "$OUTPUT_DIR/$n" ]]; then
			echo "$OUTPUT_DIR/$n"
			return 0
		fi
	fi
	latest=""
	# shellcheck disable=SC2045
	for f in $(ls -1t "$OUTPUT_DIR"/telmi-r36-*.img 2>/dev/null); do
		base="$(basename "$f")"
		case "$base" in
			telmi-r36-v30-*) continue ;;
		esac
		latest="$f"
		break
	done
	[[ -n "$latest" && -f "$latest" ]] || return 1
	echo "$latest"
}
